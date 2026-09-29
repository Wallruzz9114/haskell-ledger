-- | Property-based tests: rules that must hold for ANY sequence of
-- operations, not just the examples we thought of.
--
-- QuickCheck generates 100 random sequences per property (see
-- Support/Generators.hs). If one fails, it "shrinks" it to the smallest
-- sequence that still fails and prints it.
module Ledger.InvariantsSpec (spec) where

import qualified Data.Map.Strict as Map
import Data.Maybe (fromJust)
import Ledger.Core
import Ledger.Types
import Support.Fixtures
import Support.Generators
import Test.Hspec
import Test.QuickCheck

spec :: Spec
spec = do
  -- "property $ \(Ops ops) -> ..." asks QuickCheck for random Ops, unpacks
  -- the list, and checks the Bool that follows.
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
