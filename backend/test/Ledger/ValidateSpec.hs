{-# LANGUAGE OverloadedStrings #-}

-- | Tests for the text rules in Ledger.Validate.
module Ledger.ValidateSpec (spec) where

import Data.Either (isLeft)
import qualified Data.Text as T
import Ledger.Validate
import Test.Hspec

spec :: Spec
spec = do
  describe "validAccountId" $ do
    it "accepts lowercase letters, digits and hyphens, trimming spaces" $
      validAccountId "  acme-ops-2 " `shouldBe` Right "acme-ops-2"
    it "rejects empty ids, capitals, spaces and slashes" $ do
      -- mapM_ runs the check on every item in the list.
      mapM_
        (\raw -> validAccountId raw `shouldSatisfy` isLeft)
        ["", "   ", "Acme", "acme ops", "acme/ops", "caf\233"]
    it "rejects ids over 64 characters" $
      validAccountId (T.replicate 65 "a") `shouldSatisfy` isLeft

  describe "validAccountName" $ do
    it "trims and accepts a normal name" $
      validAccountName " Acme Operating " `shouldBe` Right "Acme Operating"
    it "rejects an empty or overlong name" $ do
      validAccountName "  " `shouldSatisfy` isLeft
      validAccountName (T.replicate 101 "x") `shouldSatisfy` isLeft

  describe "validMemo" $ do
    it "allows an empty memo" $
      validMemo "" `shouldBe` Right ""
    it "rejects a memo over 500 characters" $
      validMemo (T.replicate 501 "x") `shouldSatisfy` isLeft

  describe "validIdempotencyKey" $ do
    it "accepts a UUID" $
      validIdempotencyKey "3f2a9c1e-8b7d-4e5f-a6b2-1c0d9e8f7a6b" `shouldSatisfy` (not . isLeft)
    it "rejects empty keys, spaces and overlong keys" $ do
      validIdempotencyKey "" `shouldSatisfy` isLeft
      validIdempotencyKey "two words" `shouldSatisfy` isLeft
      validIdempotencyKey (T.replicate 256 "k") `shouldSatisfy` isLeft
