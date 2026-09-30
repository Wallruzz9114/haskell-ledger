{-# LANGUAGE OverloadedStrings #-}

-- | Values shared by several spec files: account ids, and shorthands for
-- building amounts, requests and ledgers.
--
-- The name doesn't end in "Spec", so hspec-discover skips it: it's a plain
-- helper module that the spec modules import.
module Support.Fixtures
  ( external
  , alice
  , bob
  , carol
  , customers
  , amount
  , transfer
  , freshLedger
  , testTime
  ) where

import Data.Maybe (fromJust)
import Data.Time (UTCTime (..), fromGregorian)
import Ledger.Core
import Ledger.Money
import Ledger.Types

-- Several names can share one type signature when separated by commas.
external, alice, bob, carol :: AccountId
external = AccountId "external"
alice = AccountId "alice"
bob = AccountId "bob"
carol = AccountId "carol"

customers :: [AccountId]
customers = [alice, bob, carol]

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
    open l (aid, kind) = either (error . show) snd (openAccount aid "test" kind Nothing l)

-- | A fixed moment for pure tests. Ledger.Core takes the time as an
-- argument (it never reads the clock), so tests can choose it.
testTime :: UTCTime
testTime = UTCTime (fromGregorian 2026 9 29) 43200 -- noon
