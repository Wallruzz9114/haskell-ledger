{-# LANGUAGE OverloadedStrings #-}

-- | The test suite: "cabal test --test-show-details=direct".
--
-- Two kinds of test live here:
--
--   * Example tests (hspec): "given THIS input, expect THAT output", like
--     Jest's describe / it / expect.
--
--   * Property tests (QuickCheck): "for ANY input, this rule holds". Instead
--     of writing examples, we describe how to generate random inputs, and
--     QuickCheck tries 100 of them per property. If one fails, it "shrinks"
--     the input to the smallest example that still fails and prints it.
--
-- Property tests work so well here because Ledger.Core is pure: running a
-- scenario is just calling functions, with no database or server to set up.
module Main (main) where

-- replicateConcurrently runs the same action many times at once, on
-- separate threads. Used below to hammer the store with parallel transfers.
import Control.Concurrent.Async (replicateConcurrently)
import Data.Either (isRight)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromJust)
import qualified Data.Text as T
import Ledger.Core
import Ledger.Money
import Ledger.Store
import Ledger.Types
import Test.Hspec
import Test.QuickCheck

-- Test fixtures -------------------------------------------------------------

-- Several names can share one type signature when separated by commas.
external, alice, bob, carol :: AccountId
external = AccountId "external"
alice = AccountId "alice"
bob = AccountId "bob"
carol = AccountId "carol"

customers :: [AccountId]
customers = [alice, bob, carol]

-- | A ledger with an external account and three empty customer accounts.
--
-- foldl walks a list, carrying a value along (like reduce in TypeScript):
-- start from emptyLedger and open each account in turn.
freshLedger :: Ledger
freshLedger = foldl open emptyLedger accounts
  where
    -- ":" puts one element on the front of a list, and the list
    -- comprehension builds (c, Customer) for each customer.
    accounts = (external, External) : [(c, Customer) | c <- customers]
    -- either f g e: if e is Left x, call f x; if Right y, call g y.
    -- Here: crash with the error (fine in a test fixture), or keep the new
    -- ledger ("snd" takes the second element of the pair).
    open l (aid, kind) = either (error . show) snd (openAccount aid "test" kind l)

-- | Build an Amount in tests without handling Maybe every time.
--
-- fromJust unwraps a Just and CRASHES on Nothing. That's acceptable in tests
-- with known-good numbers, but avoid it in real code: it throws away the
-- safety that Maybe gives you.
amount :: Integer -> Amount
amount = fromJust . mkAmount

-- | Shorthand for a transfer request with an empty memo.
transfer :: AccountId -> AccountId -> Integer -> TransferRequest
transfer from to n = TransferRequest from to (amount n) ""

-- Random scenario generator --------------------------------------------------

-- | Generate random operations: deposits from outside, and transfers between
-- customers, some of which will (correctly) fail for insufficient funds.
--
-- A newtype around the list gives us somewhere to attach our own
-- Arbitrary instance: "how to make a random Ops".
newtype Ops = Ops [TransferRequest]
  deriving (Show)

-- Arbitrary is QuickCheck's class for "types it knows how to generate".
instance Arbitrary Ops where
  -- listOf: a random-length list of op.
  arbitrary = Ops <$> listOf op
    where
      -- oneof: pick one of these generators at random each time.
      --   elements xs         -> a random element of xs
      --   chooseInteger (a,b) -> a random integer between a and b
      -- The "<$> ... <*> ..." style fills transfer's arguments with random
      -- values, the same shape as the JSON parsers in Ledger.App.
      op =
        oneof
          [ -- a deposit: external -> a random customer
            transfer external <$> elements customers <*> chooseInteger (1, 10000)
          , -- a customer-to-customer transfer (may be the same account, or
            -- more than the balance: those SHOULD be rejected)
            transfer <$> elements customers <*> elements customers <*> chooseInteger (1, 10000)
          ]

-- | Apply operations, ignoring the ones the ledger rejects, and return every
-- intermediate state so properties can check the invariants at each step.
--
-- scanl is like foldl but keeps every intermediate result:
--   scanl step start [op1, op2] == [start, after op1, after op1 and op2]
runOps :: [TransferRequest] -> [Ledger]
runOps = scanl step freshLedger
  where
    -- A rejected transfer (Left) leaves the ledger unchanged ("const l"
    -- ignores the error and returns l); an accepted one gives the new ledger.
    step l req = either (const l) snd (applyTransfer req l)

-- The tests --------------------------------------------------------------------

main :: IO ()
-- hspec runs the whole tree of describe / it blocks and prints the results.
main = hspec $ do
  describe "Ledger.Money" $ do
    it "rejects zero and negative amounts" $ do
      -- `shouldBe` is expect(a).toEqual(b). Backticks make the function
      -- infix, so it reads like a sentence.
      mkAmount 0 `shouldBe` Nothing
      mkAmount (-5) `shouldBe` Nothing
    it "accepts positive amounts" $
      unAmount <$> mkAmount 42 `shouldBe` Just (Cents 42)

  describe "applyTransfer" $ do
    -- "fst <$> result" keeps just the Transfer (or the error), dropping the
    -- new ledger, so we can compare it with an expected value.
    it "refuses to overdraw a customer account" $
      fst <$> applyTransfer (transfer alice bob 100) freshLedger
        `shouldBe` Left (InsufficientFunds (Cents 0) (Cents 100))
    it "refuses a transfer to the same account" $
      fst <$> applyTransfer (transfer external external 1) freshLedger `shouldBe` Left SameAccount
    it "refuses unknown accounts" $
      fst <$> applyTransfer (transfer alice (AccountId "nobody") 1) freshLedger
        `shouldBe` Left (UnknownAccount (AccountId "nobody"))
    it "moves money and writes two balancing entries" $ do
      let ok = either (error . show) snd
          l1 = ok (applyTransfer (transfer external alice 500) freshLedger)
          l2 = ok (applyTransfer (transfer alice bob 200) l1)
      -- Plain numbers like 300 work as Cents because Cents derives Num.
      balanceOf alice l2 `shouldBe` Just 300
      balanceOf bob l2 `shouldBe` Just 200
      -- alice's entries (+500, -200) add up to her balance.
      sum . map entryAmount <$> entriesFor alice l2 `shouldBe` Just 300

  describe "ledger invariants (property-based)" $ do
    -- "property $ \(Ops ops) -> ..." asks QuickCheck for random Ops, unpacks
    -- the list, and checks the Bool that follows. 100 random runs each.
    it "the sum of all balances is always zero" $
      -- all p xs: True if p holds for every element. Checked after EVERY
      -- step, not just at the end.
      property $ \(Ops ops) -> all ((== 0) . totalOfAllBalances) (runOps ops)
    it "no customer account ever goes negative" $
      property $ \(Ops ops) ->
        all (\l -> all (\c -> fromJust (balanceOf c l) >= 0) customers) (runOps ops)
    it "every balance equals the sum of that account's entries" $
      property $ \(Ops ops) ->
        -- last: the final state after all operations.
        let l = last (runOps ops)
         in all
              (\(aid, bal) -> Just bal == (sum . map entryAmount <$> entriesFor aid l))
              (Map.toList (allBalances l))

  describe "in-memory store" $ do
    it "replays an idempotent request instead of applying it twice" $ do
      store <- seededStore
      let key = Just (IdempotencyKey "payroll-2026-09")
          req = transfer alice bob 300
      first <- storeTransfer store key req
      second <- storeTransfer store key req
      second `shouldBe` first
      -- `shouldReturn` runs an IO action and compares its result.
      -- 1000 seeded - 300 moved ONCE = 700.
      fmap snd <$> storeGetAccount store alice `shouldReturn` Just 700

    it "rejects a reused idempotency key with a different request" $ do
      store <- seededStore
      let key = Just (IdempotencyKey "k1")
      _ <- storeTransfer store key (transfer alice bob 300)
      storeTransfer store key (transfer alice bob 999) `shouldReturn` Left IdempotencyKeyReused

    it "never overdraws under concurrent transfers" $ do
      store <- seededStore
      -- 1000 cents available; 200 concurrent attempts to move 10 cents each.
      -- Exactly 100 can succeed. Without STM, two threads could both read
      -- "10 left" and both spend it.
      results <- replicateConcurrently 200 (storeTransfer store Nothing (transfer alice bob 10))
      length (filter isRight results) `shouldBe` 100
      fmap snd <$> storeGetAccount store alice `shouldReturn` Just 0
      fmap snd <$> storeGetAccount store bob `shouldReturn` Just 1000
  where
    -- A fresh store per test: external, three customers, and 1000 cents
    -- deposited into alice. Each test gets its own, so they can't interfere.
    seededStore = do
      store <- newInMemoryStore
      -- mapM_ runs an action for each list element and discards the results
      -- (like forEach with an async callback).
      mapM_
        (\(aid, kind) -> storeOpenAccount store aid (T.pack (show aid)) kind)
        ((external, External) : [(c, Customer) | c <- customers])
      _ <- storeTransfer store Nothing (transfer external alice 1000)
      pure store
