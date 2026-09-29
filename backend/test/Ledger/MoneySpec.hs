-- | Tests for Ledger.Money: the smart constructor for amounts.
--
-- Every spec module exports one value, "spec :: Spec". hspec-discover (see
-- test/Spec.hs) finds it and groups its tests under the module name, so
-- these show up as "Ledger.Money" in the output.
module Ledger.MoneySpec (spec) where

import Ledger.Money
import Test.Hspec

spec :: Spec
spec = do
  it "rejects zero and negative amounts" $ do
    -- `shouldBe` is expect(a).toEqual(b). Backticks make the function
    -- infix, so it reads like a sentence.
    mkAmount 0 `shouldBe` Nothing
    mkAmount (-5) `shouldBe` Nothing

  it "accepts positive amounts" $
    unAmount <$> mkAmount 42 `shouldBe` Just (Cents 42)
