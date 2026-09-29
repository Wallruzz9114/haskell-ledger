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
    it "reads hashes made by other Argon2 tools (the standard PHC format)" $ do
      -- Made by the Haskell "password" library for the demo password, which
      -- is public (see the README). If our encoding ever drifted from the
      -- standard format, existing users could no longer log in.
      let fromAnotherTool = "$argon2id$v=19$m=65536,t=2,p=1$/PfMseOUhIiO22/yEKcakw$JtRBbqlAxNwQ9JLhZTHfY0DszLLo91/MJuoEvjgZl0o"
      passwordMatches "ledger-demo-2026" fromAnotherTool `shouldBe` True
      passwordMatches "ledger-demo-2027" fromAnotherTool `shouldBe` False
    it "rejects anything that isn't a well-formed hash, instead of crashing" $ do
      passwordMatches "x" "" `shouldBe` False
      passwordMatches "x" "not a hash" `shouldBe` False
      passwordMatches "x" "$argon2id$v=19$m=lots,t=2,p=1$abc$def" `shouldBe` False
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
