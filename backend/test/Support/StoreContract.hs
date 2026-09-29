{-# LANGUAGE OverloadedStrings #-}

-- | The tests every LedgerStore must pass, whatever it's backed by.
--
-- "Contract" because this is the promise the LedgerStore interface makes to
-- its callers. Ledger/StoreSpec.hs runs it against the in-memory store and
-- Ledger/Store/PostgresSpec.hs against Postgres. If both pass, callers
-- really can't tell the two apart.
module Support.StoreContract
  ( storeContract
  ) where

import Control.Concurrent.Async (forConcurrently, replicateConcurrently)
import Data.Bifunctor (first)
import Data.Either (isRight)
import qualified Data.Text as T
import Ledger.Money
import Ledger.Store
import Ledger.Types
import Support.Fixtures
import Test.Hspec

-- | Every store test, given a way to make an EMPTY store.
--
-- Taking the store-maker as an argument is what lets one set of tests run
-- against both implementations: this function doesn't know which it has.
storeContract :: IO LedgerStore -> Spec
storeContract emptyStore = do
  it "replays an idempotent request instead of applying it twice" $ do
    store <- seeded
    let key = Just (IdempotencyKey "payroll-2026-09")
        req = transfer alice bob 300
    firstTry <- storeTransfer store key req
    retry <- storeTransfer store key req
    retry `shouldBe` firstTry
    -- `shouldReturn` runs an IO action and compares its result.
    -- 1000 seeded - 300 moved ONCE = 700.
    fmap snd <$> storeGetAccount store alice `shouldReturn` Just 700

  it "rejects a reused idempotency key with a different request" $ do
    store <- seeded
    let key = Just (IdempotencyKey "k1")
    _ <- storeTransfer store key (transfer alice bob 300)
    storeTransfer store key (transfer alice bob 999) `shouldReturn` Left IdempotencyKeyReused

  it "remembers a failed request, even after the balance changes" $ do
    store <- seeded
    let key = Just (IdempotencyKey "too-early")
        req = transfer bob carol 50
    -- bob has nothing yet, so this fails...
    storeTransfer store key req `shouldReturn` Left (InsufficientFunds (Cents 0) (Cents 50))
    -- ...then bob gets money...
    _ <- storeTransfer store Nothing (transfer alice bob 100)
    -- ...but a retry with the same key gets the ORIGINAL answer, and no
    -- money moves. A retry must never change the outcome.
    storeTransfer store key req `shouldReturn` Left (InsufficientFunds (Cents 0) (Cents 50))
    fmap snd <$> storeGetAccount store carol `shouldReturn` Just 0

  it "reports unknown and duplicate accounts" $ do
    store <- seeded
    storeGetAccount store (AccountId "nobody") `shouldReturn` Nothing
    storeEntries store (AccountId "nobody") `shouldReturn` Nothing
    storeEntries store carol `shouldReturn` Just []
    storeOpenAccount store alice "again" Customer `shouldReturn` Left (AccountAlreadyExists alice)

  it "lists accounts in id order with their balances" $ do
    store <- seeded
    -- "first f" applies f to the first half of a pair: (a, b) -> (f a, b).
    map (first accountId) <$> storeListAccounts store
      `shouldReturn` [(alice, 1000), (bob, 0), (carol, 0), (external, -1000)]

  it "never overdraws under concurrent transfers" $ do
    store <- seeded
    -- 1000 cents available; 200 concurrent attempts to move 10 cents each.
    -- Exactly 100 can succeed. Without STM (in memory) or row locks
    -- (Postgres), two threads could both read "10 left" and both spend it.
    results <- replicateConcurrently 200 (storeTransfer store Nothing (transfer alice bob 10))
    length (filter isRight results) `shouldBe` 100
    fmap snd <$> storeGetAccount store alice `shouldReturn` Just 0
    fmap snd <$> storeGetAccount store bob `shouldReturn` Just 1000

  it "handles transfers in opposite directions at the same time" $ do
    store <- seeded
    _ <- storeTransfer store Nothing (transfer alice bob 500)
    -- 200 concurrent 1-cent transfers, half alice->bob and half bob->alice.
    -- In Postgres, locking rows in a fixed order stops two of these from
    -- each holding one account while waiting for the other (a deadlock).
    -- forConcurrently runs the function for every list item at once.
    results <- forConcurrently [1 .. 200 :: Int] $ \i ->
      storeTransfer store Nothing (if even i then transfer alice bob 1 else transfer bob alice 1)
    all isRight results `shouldBe` True
    -- Equal traffic both ways: the balances end where they started.
    fmap snd <$> storeGetAccount store alice `shouldReturn` Just 500
    fmap snd <$> storeGetAccount store bob `shouldReturn` Just 500
  where
    -- A fresh store per test: external, three customers, and 1000 cents
    -- deposited into alice. Each test gets its own, so they can't interfere.
    seeded = do
      store <- emptyStore
      -- mapM_ runs an action for each list element and discards the results
      -- (like forEach with an async callback).
      mapM_
        (\(aid, kind) -> storeOpenAccount store aid (T.pack (show aid)) kind)
        ((external, External) : [(c, Customer) | c <- customers])
      _ <- storeTransfer store Nothing (transfer external alice 1000)
      pure store
