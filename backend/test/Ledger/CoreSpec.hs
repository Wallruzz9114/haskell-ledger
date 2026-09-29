{-# LANGUAGE OverloadedStrings #-}

-- | Example tests for Ledger.Core: specific inputs, specific expected results.
-- The random, property-based tests for the same module are in
-- Ledger/InvariantsSpec.hs.
module Ledger.CoreSpec (spec) where

import Ledger.Core
import Ledger.Money
import Ledger.Types
import Support.Fixtures
import Test.Hspec

spec :: Spec
spec = do
  describe "checkTransfer" $ do
    -- checkTransfer is the rulebook on its own: no ledger needed, just the
    -- two accounts (or Nothing) and the sender's balance.
    let customer aid = Just (Account aid "test" Customer)
    it "reports the first missing account" $
      checkTransfer (transfer alice bob 1) Nothing (customer bob) 100
        `shouldBe` Left (UnknownAccount alice)
    it "lets a customer spend exactly their whole balance" $
      checkTransfer (transfer alice bob 100) (customer alice) (customer bob) 100
        `shouldBe` Right ()
    it "lets the external account go negative" $
      checkTransfer (transfer external bob 100) (Just (Account external "test" External)) (customer bob) 0
        `shouldBe` Right ()

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

  describe "openAccount" $
    it "refuses an id that's already taken" $
      fst <$> openAccount alice "again" Customer freshLedger `shouldBe` Left (AccountAlreadyExists alice)
