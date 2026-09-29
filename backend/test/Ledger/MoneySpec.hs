-- | Tests for Ledger.Money: the smart constructor for amounts.
--
-- Every spec module exports one value, "spec :: Spec". hspec-discover (see
-- test/Spec.hs) finds it and groups its tests under the module name, so
-- these show up as "Ledger.Money" in the output.
{-# LANGUAGE OverloadedStrings #-}

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

  it "accepts up to maxAmount and rejects anything bigger" $ do
    unAmount <$> mkAmount maxAmount `shouldBe` Just (Cents maxAmount)
    -- 10^20 cents: larger than a Postgres bigint can hold.
    mkAmount (maxAmount + 1) `shouldBe` Nothing
    mkAmount (10 ^ (20 :: Int)) `shouldBe` Nothing

  describe "formatCents" $ do
    it "formats dollars with thousands separators and two decimals" $ do
      formatCents 125050 `shouldBe` "$1,250.50"
      formatCents 100000000 `shouldBe` "$1,000,000.00"
      formatCents 0 `shouldBe` "$0.00"
    it "puts the sign before the dollar sign" $
      formatCents (-5) `shouldBe` "-$0.05"
