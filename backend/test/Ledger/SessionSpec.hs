{-# LANGUAGE OverloadedStrings #-}

-- | Tests for password hashing and session tokens in Ledger.Session.
module Ledger.SessionSpec (spec) where

import qualified Data.Text as T
import Ledger.Session
import Test.Hspec

spec :: Spec
spec = do
  describe "passwords" $ do
    it "matches the right password and rejects a wrong one" $ do
      hash <- hashPassword "correct horse"
      passwordMatches "correct horse" hash `shouldBe` True
      passwordMatches "wrong horse" hash `shouldBe` False
    it "salts: the same password hashes differently each time" $ do
      first <- hashPassword "same password"
      second <- hashPassword "same password"
      first `shouldNotBe` second
    it "never stores the password itself" $ do
      hash <- hashPassword "correct horse"
      hash `shouldSatisfy` (not . T.isInfixOf "correct horse")

  describe "session tokens" $ do
    it "are different every time" $ do
      (a, _) <- newSessionToken
      (b, _) <- newSessionToken
      a `shouldNotBe` b
    it "hash the same way when the cookie comes back" $ do
      (token, tokenHash) <- newSessionToken
      hashToken token `shouldBe` tokenHash
    it "are long enough not to be guessed (32 random bytes)" $ do
      (token, _) <- newSessionToken
      -- 32 bytes in base64 without padding is 43 characters.
      T.length token `shouldBe` 43
