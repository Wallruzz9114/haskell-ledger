{-# LANGUAGE OverloadedStrings #-}

-- | Tests for the permission rules in Ledger.Auth.
module Ledger.AuthSpec (spec) where

import Ledger.Auth
import Ledger.Types
import Test.Hspec

alice, bob, admin :: User
alice = User (Username "alice") RoleCustomer
bob = User (Username "bob") RoleCustomer
admin = User (Username "admin") RoleAdmin

acmeOps, external :: Account
acmeOps = Account (AccountId "acme-ops") "Acme Operating" Customer (Just (Username "alice"))
external = Account (AccountId "external") "External" External Nothing

spec :: Spec
spec = do
  describe "canView" $ do
    it "lets owners and admins see an account, and nobody else" $ do
      canView alice acmeOps `shouldBe` True
      canView admin acmeOps `shouldBe` True
      canView bob acmeOps `shouldBe` False
    it "hides system accounts from customers" $ do
      canView alice external `shouldBe` False
      canView admin external `shouldBe` True

  describe "canSendFrom" $ do
    it "lets only the owner send, not even an admin" $ do
      canSendFrom alice acmeOps `shouldBe` True
      canSendFrom bob acmeOps `shouldBe` False
      canSendFrom admin acmeOps `shouldBe` False
    it "lets nobody send from an unowned system account" $
      map (`canSendFrom` external) [alice, bob, admin] `shouldBe` [False, False, False]

  describe "canDeposit" $
    it "is for admins only" $
      map canDeposit [alice, admin] `shouldBe` [False, True]

  describe "canOpenAccountFor" $
    it "lets customers open accounts for themselves, and admins for anyone" $ do
      canOpenAccountFor alice (Username "alice") `shouldBe` True
      canOpenAccountFor alice (Username "bob") `shouldBe` False
      canOpenAccountFor admin (Username "bob") `shouldBe` True

  describe "inOverview" $ do
    it "covers a customer's own accounts only" $ do
      inOverview alice acmeOps `shouldBe` True
      inOverview bob acmeOps `shouldBe` False
    it "covers every customer account for an admin, but never external" $ do
      inOverview admin acmeOps `shouldBe` True
      inOverview admin external `shouldBe` False
