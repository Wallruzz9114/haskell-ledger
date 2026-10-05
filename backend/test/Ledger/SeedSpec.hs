{-# LANGUAGE OverloadedStrings #-}

-- | Tests for Ledger.Seed: the demo data is valid, owned by the right demo
-- users, dated up to "now", and seeding is repeatable.
module Ledger.SeedSpec (spec) where

import Control.Exception (IOException, try)
import Data.Either (isLeft)
import Data.List (nub, sort)
import Data.Time (UTCTime (..), addUTCTime, fromGregorian, nominalDay)
import Ledger.Seed
import Ledger.Session (passwordMatches)
import Ledger.Store
import Ledger.Types
import Test.Hspec

-- | October 5, 2026, mid-afternoon UTC: "today" for most tests here.
today :: UTCTime
today = UTCTime (fromGregorian 2026 10 5) (15 * 3600)

-- | Fresh in-memory stores with the demo data in them, seeded "today".
seeded :: IO (LedgerStore, UserStore)
seeded = do
  store <- newInMemoryStore
  users <- newInMemoryUserStore
  seedDemoDataAt today "test-password" store users
  pure (store, users)

spec :: Spec
spec = do
  it "applies every demo transfer (seedDemoData fails if any is rejected)" $ do
    (store, _) <- seeded
    -- 7 accounts: external plus six demo accounts.
    length <$> storeListAccounts store `shouldReturn` 7

  it "leaves every customer account non-negative, and the total at zero" $ do
    (store, _) <- seeded
    balances <- storeListAccounts store
    -- sum of every balance: double-entry means it's always zero.
    sum (map snd balances) `shouldBe` 0
    [a | (a, bal) <- balances, accountKind a == Customer, bal < 0] `shouldBe` []

  it "creates the demo users with the given password" $ do
    (_, users) <- seeded
    found <- storeFindUser users (Username "alice")
    fmap fst found `shouldBe` Just (User (Username "alice") RoleCustomer)
    fmap (passwordMatches "test-password" . snd) found `shouldBe` Just True
    fmap (userRole . fst) <$> storeFindUser users (Username "admin") `shouldReturn` Just RoleAdmin

  it "gives alice the Acme accounts and bob the Globex ones" $ do
    (store, _) <- seeded
    accounts <- storeListAccounts store
    let ownerOf aid = [accountOwner a | (a, _) <- accounts, accountId a == AccountId aid]
    ownerOf "acme-ops" `shouldBe` [Just (Username "alice")]
    ownerOf "globex-payroll" `shouldBe` [Just (Username "bob")]
    ownerOf "external" `shouldBe` [Nothing]

  it "dates the history over the last three months and this one, oldest first" $ do
    (store, _) <- seeded
    Just entries <- storeEntries store (AccountId "acme-ops")
    -- Entries come newest first, so reversed they should be in date order.
    let dates = map entryCreatedAt (reverse entries)
    dates `shouldBe` sort dates
    -- From July 1 up to today: nothing dated in the future.
    map utctDay dates `shouldSatisfy` all (>= fromGregorian 2026 7 1)
    dates `shouldSatisfy` all (<= today)
    -- This month already has activity, so its dashboard isn't empty.
    map utctDay dates `shouldSatisfy` any (>= fromGregorian 2026 10 1)
    -- Spread across the months, not all stamped at one moment.
    length (nub dates) `shouldBe` length dates

  it "adds only the newer transfers when run again weeks later" $ do
    (store, users) <- seeded
    countBefore <- length <$> storeEntriesFor store [AccountId "acme-ops"]
    -- Seven weeks on: a different window of months, but every key it
    -- shares with the first run means the same transfer, so nothing is
    -- refused (seedDemoDataAt fails if anything is).
    seedDemoDataAt (addUTCTime (49 * nominalDay) today) "test-password" store users
    countAfter <- length <$> storeEntriesFor store [AccountId "acme-ops"]
    countAfter `shouldSatisfy` (> countBefore)
    balances <- storeListAccounts store
    sum (map snd balances) `shouldBe` 0

  it "applies cleanly whatever day it's first run on" $ do
    -- One users store for every run: creating users hashes passwords,
    -- which is slow on purpose.
    users <- newInMemoryUserStore
    -- The 1st, 15th and 28th of every month for two years, each into an
    -- empty ledger. Covers a quarter-end month first in the window, the
    -- turn of the year, February and both sides of daylight saving time.
    let starts = [UTCTime (fromGregorian y m d) (12 * 3600) | y <- [2026, 2027], m <- [1 .. 12], d <- [1, 15, 28]]
    mapM_
      ( \now -> do
          store <- newInMemoryStore
          seedDemoDataAt now "pw" store users
          balances <- storeListAccounts store
          [a | (a, bal) <- balances, accountKind a == Customer, bal < 0] `shouldBe` []
      )
      starts

  it "changes nothing when run a second time" $ do
    (store, users) <- seeded
    once <- storeListAccounts store
    aliceBefore <- storeFindUser users (Username "alice")
    -- A different password on the second run: existing users keep theirs.
    seedDemoDataAt today "another-password" store users
    storeListAccounts store `shouldReturn` once
    storeFindUser users (Username "alice") `shouldReturn` aliceBefore

  it "gives a demo account left over from before users existed its owner" $ do
    store <- newInMemoryStore
    users <- newInMemoryUserStore
    -- An account from before accounts had owners.
    _ <- storeOpenAccount store (AccountId "acme-ops") "Acme Operating" Customer Nothing
    seedDemoData "pw" store users
    fmap (accountOwner . fst) <$> storeGetAccount store (AccountId "acme-ops") `shouldReturn` Just (Just (Username "alice"))

  it "refuses to take over a demo account that belongs to someone else" $ do
    store <- newInMemoryStore
    users <- newInMemoryUserStore
    _ <- storeOpenAccount store (AccountId "acme-ops") "Somebody Else's" Customer (Just (Username "mallory"))
    -- "try" catches the exception and returns it as a Left instead of
    -- letting it crash the test. "fail" in IO throws an IOException.
    result <- try (seedDemoData "pw" store users) :: IO (Either IOException ())
    result `shouldSatisfy` isLeft
