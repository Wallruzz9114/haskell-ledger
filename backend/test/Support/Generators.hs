-- | Random test data for QuickCheck: sequences of deposits and transfers.
module Support.Generators
  ( Ops (..)
  , runOps
  ) where

import Ledger.Core
import Ledger.Types
import Support.Fixtures
import Test.QuickCheck

-- | Random operations: deposits from outside, and transfers between
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
