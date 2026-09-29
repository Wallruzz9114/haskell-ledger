{-# LANGUAGE OverloadedStrings #-}

-- | HTTP-level tests for Ledger.App: status codes and error codes, exactly as
-- a client sees them.
--
-- hspec-wai hands requests straight to the Application in memory: no server,
-- no port, no network. "with" builds a fresh app (with a freshly seeded
-- in-memory store) before every test, so tests can't affect each other.
module Ledger.AppSpec (spec) where

import Control.Exception (throwIO)
import Data.Aeson (Value (..), decode)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Ledger.App (Env (..), app)
import Ledger.Seed (seedDemoData)
import Ledger.Store
import Network.HTTP.Types (methodPost)
import Network.Wai (RequestBodyLength (..), defaultRequest, requestBodyLength, requestMethod)
import qualified Network.Wai.Test as WaiTest
import Test.Hspec
import Test.Hspec.Wai

spec :: Spec
spec = do
  describe "with the demo data" $ with (app . Env =<< seededStore) $ do
    it "answers the health check" $
      get "/api/health" `shouldRespondWith` 200

    it "lists accounts" $
      get "/api/accounts" `shouldRespondWith` 200

    it "opens an account, then refuses the same id again" $ do
      post "/api/accounts" "{\"id\": \"initech-ops\", \"name\": \"Initech\"}" `shouldRespondWith` 201
      post "/api/accounts" "{\"id\": \"initech-ops\", \"name\": \"Again\"}" `shouldRespondWith` errorCode 409 "account_exists"

    it "rejects account ids that couldn't be used in a URL" $ do
      post "/api/accounts" "{\"id\": \"has space/slash\", \"name\": \"x\"}" `shouldRespondWith` errorCode 400 "invalid_account_id"
      post "/api/accounts" "{\"id\": \"\", \"name\": \"x\"}" `shouldRespondWith` errorCode 400 "invalid_account_id"
      post "/api/accounts" "{\"id\": \"ok-id\", \"name\": \"  \"}" `shouldRespondWith` errorCode 400 "invalid_account_name"

    it "returns 404 for an unknown account" $ do
      get "/api/accounts/nobody" `shouldRespondWith` errorCode 404 "unknown_account"
      get "/api/accounts/nobody/entries" `shouldRespondWith` errorCode 404 "unknown_account"

    it "moves money" $
      transferJson "{\"from\": \"acme-ops\", \"to\": \"acme-payroll\", \"amountCents\": 100}" `shouldRespondWith` 201

    it "maps each transfer error to its status and code" $ do
      transferJson "{\"from\": \"acme-payroll\", \"to\": \"acme-ops\", \"amountCents\": 99999999}"
        `shouldRespondWith` errorCode 422 "insufficient_funds"
      transferJson "{\"from\": \"acme-ops\", \"to\": \"acme-ops\", \"amountCents\": 1}"
        `shouldRespondWith` errorCode 422 "same_account"
      transferJson "{\"from\": \"acme-ops\", \"to\": \"nobody\", \"amountCents\": 1}"
        `shouldRespondWith` errorCode 404 "unknown_account"

    it "rejects zero, negative and too-large amounts with 400, not a crash" $ do
      transferJson "{\"from\": \"acme-ops\", \"to\": \"acme-payroll\", \"amountCents\": 0}"
        `shouldRespondWith` errorCode 400 "invalid_amount"
      transferJson "{\"from\": \"acme-ops\", \"to\": \"acme-payroll\", \"amountCents\": -5}"
        `shouldRespondWith` errorCode 400 "invalid_amount"
      transferJson "{\"from\": \"acme-ops\", \"to\": \"acme-payroll\", \"amountCents\": 100000000000000000000}"
        `shouldRespondWith` errorCode 400 "invalid_amount"

    it "rejects malformed JSON and overlong memos" $ do
      transferJson "{\"from\": 1}" `shouldRespondWith` errorCode 400 "bad_request"
      transferJson ("{\"from\": \"acme-ops\", \"to\": \"acme-payroll\", \"amountCents\": 1, \"memo\": \"" <> BL.replicate 501 120 <> "\"}")
        `shouldRespondWith` errorCode 400 "invalid_memo"

    it "replays a request sent twice with the same Idempotency-Key" $ do
      let send = keyedTransfer "retry-1" "{\"from\": \"acme-ops\", \"to\": \"acme-payroll\", \"amountCents\": 100}"
      first <- send
      second <- send
      -- liftIO runs a plain IO assertion inside the WaiSession.
      liftIO $ do
        simpleStatus second `shouldBe` simpleStatus first
        simpleBody second `shouldBe` simpleBody first

    it "rejects an Idempotency-Key with spaces" $
      keyedTransfer "two words" "{\"from\": \"acme-ops\", \"to\": \"acme-payroll\", \"amountCents\": 1}"
        `shouldRespondWith` errorCode 400 "invalid_idempotency_key"

    it "answers unknown URLs with a JSON 404" $
      get "/api/nope" `shouldRespondWith` errorCode 404 "not_found"

  describe "request size" $
    it "refuses request bodies over 64 KB" $ do
      -- hspec-wai's helpers send bodies in a way the size check can't see,
      -- so this test builds the request by hand, the way Warp would for a
      -- request whose Content-Length says 70,000 bytes.
      application <- app . Env =<< seededStore
      let oversized =
            WaiTest.setPath
              defaultRequest {requestMethod = methodPost, requestBodyLength = KnownLength 70000}
              "/api/transfers"
      response <- WaiTest.runSession (WaiTest.request oversized) application
      errorCodeOf (simpleBody response) `shouldBe` Just "payload_too_large"

  describe "when the store crashes" $ with (app (Env crashingStore)) $
    it "answers with a JSON 500 that doesn't leak the error's details" $ do
      response <- get "/api/accounts"
      liftIO $ do
        errorCodeOf (simpleBody response) `shouldBe` Just "internal_error"
        -- BS.isInfixOf: does the first text appear anywhere in the second?
        BL.toStrict (simpleBody response) `shouldNotSatisfy` BS.isInfixOf "internal detail"

-- Helpers -----------------------------------------------------------------------

seededStore :: IO LedgerStore
seededStore = do
  store <- newInMemoryStore
  seedDemoData store
  pure store

-- | A store where every operation throws, standing in for "the database is
-- down". "_" arguments are ignored; "const x" is a function ignoring its
-- one argument and returning x.
crashingStore :: LedgerStore
crashingStore =
  LedgerStore
    { storeOpenAccount = \_ _ _ -> boom
    , storeGetAccount = const boom
    , storeListAccounts = boom
    , storeEntries = const boom
    , storeTransfer = \_ _ -> boom
    }
  where
    boom :: IO a
    boom = throwIO (userError "internal detail")

transferJson :: BL.ByteString -> WaiSession st SResponse
transferJson = post "/api/transfers"

keyedTransfer :: BL.ByteString -> BL.ByteString -> WaiSession st SResponse
keyedTransfer key =
  request methodPost "/api/transfers" [("Content-Type", "application/json"), ("Idempotency-Key", BL.toStrict key)]

-- | Match a response by status AND the "error" field of its JSON body.
errorCode :: Int -> Text -> ResponseMatcher
errorCode st code = ResponseMatcher st [] (MatchBody check)
  where
    check _ body
      | errorCodeOf body == Just code = Nothing
      | otherwise = Just ("expected error code " <> show code <> ", got body " <> show body)

-- | The "error" field of a JSON error body, if there is one.
errorCodeOf :: BL.ByteString -> Maybe Text
errorCodeOf body = do
  fields <- decode body :: Maybe (Map.Map Text Value)
  String code <- Map.lookup "error" fields
  pure code
