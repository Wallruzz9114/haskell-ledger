{-# LANGUAGE OverloadedStrings #-}

-- | HTTP-level tests for Ledger.App: logging in, who may do what, and every
-- status and error code, exactly as a client sees them.
--
-- hspec-wai hands requests straight to the Application in memory: no server,
-- no port, no network. "with" builds a fresh app (with freshly seeded
-- in-memory stores) before every test, so tests can't affect each other.
--
-- The demo users (see Ledger.Seed): alice owns the acme-* accounts, bob owns
-- the globex-* accounts, and admin can see everything and make deposits.
module Ledger.AppSpec (spec) where

import Control.Exception (throwIO)
import Data.Aeson (Value (..), decode, encode, object, (.=))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Ledger.App (CookiePolicy (..), app, newEnv)
import Ledger.Seed (seedDemoData)
import Ledger.Session (hashPassword)
import Ledger.Store
import Ledger.Types
import Network.HTTP.Types (Header, methodGet, methodPost, methodPut)
import Network.Wai (Application, RequestBodyLength (..), defaultRequest, requestBodyLength, requestHeaders, requestMethod)
import qualified Network.Wai.Test as WaiTest
import Test.Hspec
import Test.Hspec.Wai

spec :: Spec
spec = do
  describe "logging in" $ with demoApp $ do
    it "requires a login for everything except the health check" $ do
      get "/api/health" `shouldRespondWith` 200
      get "/api/accounts" `shouldRespondWith` errorCode 401 "unauthorized"
      get "/api/me" `shouldRespondWith` errorCode 401 "unauthorized"

    it "gives the same answer for a wrong password and an unknown user" $ do
      login "alice" "wrong-password" `shouldRespondWith` errorCode 401 "invalid_credentials"
      login "nobody" "test-password" `shouldRespondWith` errorCode 401 "invalid_credentials"

    it "sets an HttpOnly, SameSite=Lax session cookie" $ do
      response <- login "alice" "test-password"
      let setCookie = lookup "Set-Cookie" (simpleHeaders response)
      liftIO $ do
        setCookie `shouldSatisfy` maybe False (BS.isInfixOf "HttpOnly")
        setCookie `shouldSatisfy` maybe False (BS.isInfixOf "SameSite=Lax")

    it "knows who is logged in, until they log out" $ do
      cookie <- loginAs "alice"
      getAs cookie "/api/me" `shouldRespondWith` 200
      postAs cookie "/api/logout" "" `shouldRespondWith` 204
      -- The same cookie no longer works: the session was deleted.
      getAs cookie "/api/me" `shouldRespondWith` errorCode 401 "unauthorized"

    it "ignores a made-up session cookie" $
      getAs "ledger_session=made-up" "/api/me" `shouldRespondWith` errorCode 401 "unauthorized"

  describe "who sees what" $ with demoApp $ do
    it "shows customers only their own accounts" $ do
      cookie <- loginAs "alice"
      response <- getAs cookie "/api/accounts"
      liftIO $ accountIds (simpleBody response) `shouldBe` Just ["acme-ops", "acme-payroll", "acme-savings", "acme-tax"]

    it "shows admins every account" $ do
      cookie <- loginAs "admin"
      response <- getAs cookie "/api/accounts"
      liftIO $ length <$> accountIds (simpleBody response) `shouldBe` Just 7

    it "answers 404 for someone else's account, as if it didn't exist" $ do
      cookie <- loginAs "alice"
      getAs cookie "/api/accounts/globex-ops" `shouldRespondWith` errorCode 404 "unknown_account"
      getAs cookie "/api/accounts/globex-ops/entries" `shouldRespondWith` errorCode 404 "unknown_account"
      getAs cookie "/api/accounts/acme-ops/entries" `shouldRespondWith` 200

  describe "who may move money" $ with demoApp $ do
    it "lets an owner send from their account to anyone's" $ do
      cookie <- loginAs "alice"
      postAs cookie "/api/transfers" (transfer "acme-ops" "globex-ops" 100) `shouldRespondWith` 201

    it "doesn't let anyone send from someone else's account" $ do
      alice <- loginAs "alice"
      postAs alice "/api/transfers" (transfer "globex-ops" "acme-ops" 100) `shouldRespondWith` errorCode 404 "unknown_account"
      -- An admin can SEE the account, so the answer is 403, not 404.
      admin <- loginAs "admin"
      postAs admin "/api/transfers" (transfer "acme-ops" "globex-ops" 100) `shouldRespondWith` errorCode 403 "forbidden"

    it "doesn't let anyone send from the external account" $ do
      cookie <- loginAs "admin"
      postAs cookie "/api/transfers" (transfer "external" "acme-ops" 100) `shouldRespondWith` errorCode 403 "forbidden"

    it "lets only admins make deposits" $ do
      alice <- loginAs "alice"
      postAs alice "/api/deposits" "{\"to\": \"acme-ops\", \"amountCents\": 100}" `shouldRespondWith` errorCode 403 "forbidden"
      admin <- loginAs "admin"
      postAs admin "/api/deposits" "{\"to\": \"acme-ops\", \"amountCents\": 100}" `shouldRespondWith` 201

  describe "opening accounts" $ with demoApp $ do
    it "opens an account for the logged-in customer, and refuses the id twice" $ do
      cookie <- loginAs "alice"
      postAs cookie "/api/accounts" "{\"id\": \"acme-travel\", \"name\": \"Acme Travel\"}" `shouldRespondWith` 201
      postAs cookie "/api/accounts" "{\"id\": \"acme-travel\", \"name\": \"Again\"}" `shouldRespondWith` errorCode 409 "account_exists"
      getAs cookie "/api/accounts/acme-travel" `shouldRespondWith` 200

    it "doesn't let a customer open an account for someone else" $ do
      cookie <- loginAs "alice"
      postAs cookie "/api/accounts" "{\"id\": \"x\", \"name\": \"X\", \"owner\": \"bob\"}" `shouldRespondWith` errorCode 403 "forbidden"

    it "lets an admin open an account for an existing user only" $ do
      cookie <- loginAs "admin"
      postAs cookie "/api/accounts" "{\"id\": \"bob-new\", \"name\": \"New\", \"owner\": \"bob\"}" `shouldRespondWith` 201
      postAs cookie "/api/accounts" "{\"id\": \"x\", \"name\": \"X\", \"owner\": \"nobody\"}" `shouldRespondWith` errorCode 404 "unknown_user"

    it "rejects account ids that couldn't be used in a URL" $ do
      cookie <- loginAs "alice"
      postAs cookie "/api/accounts" "{\"id\": \"has space/slash\", \"name\": \"x\"}" `shouldRespondWith` errorCode 400 "invalid_account_id"
      postAs cookie "/api/accounts" "{\"id\": \"ok-id\", \"name\": \"  \"}" `shouldRespondWith` errorCode 400 "invalid_account_name"

  describe "transfer errors" $ with demoApp $ do
    it "maps each transfer error to its status and code" $ do
      cookie <- loginAs "alice"
      postAs cookie "/api/transfers" (transfer "acme-payroll" "acme-ops" 99999999) `shouldRespondWith` errorCode 422 "insufficient_funds"
      postAs cookie "/api/transfers" (transfer "acme-ops" "acme-ops" 1) `shouldRespondWith` errorCode 422 "same_account"
      postAs cookie "/api/transfers" (transfer "acme-ops" "nobody" 1) `shouldRespondWith` errorCode 404 "unknown_account"

    it "rejects zero, negative and too-large amounts with 400, not a crash" $ do
      cookie <- loginAs "alice"
      postAs cookie "/api/transfers" (transfer "acme-ops" "acme-payroll" 0) `shouldRespondWith` errorCode 400 "invalid_amount"
      postAs cookie "/api/transfers" (transfer "acme-ops" "acme-payroll" (-5)) `shouldRespondWith` errorCode 400 "invalid_amount"
      postAs cookie "/api/transfers" (transfer "acme-ops" "acme-payroll" (10 ^ (20 :: Int))) `shouldRespondWith` errorCode 400 "invalid_amount"

    it "rejects malformed JSON and overlong memos" $ do
      cookie <- loginAs "alice"
      postAs cookie "/api/transfers" "{\"from\": 1}" `shouldRespondWith` errorCode 400 "bad_request"
      let longMemo = encode (object ["from" .= ("acme-ops" :: Text), "to" .= ("acme-payroll" :: Text), "amountCents" .= (1 :: Int), "memo" .= T.replicate 501 "x"])
      postAs cookie "/api/transfers" longMemo `shouldRespondWith` errorCode 400 "invalid_memo"

  describe "idempotency keys" $ with demoApp $ do
    it "replays a request sent twice with the same key" $ do
      cookie <- loginAs "alice"
      first <- keyedTransfer cookie "retry-1" (transfer "acme-ops" "acme-payroll" 100)
      second <- keyedTransfer cookie "retry-1" (transfer "acme-ops" "acme-payroll" 100)
      liftIO $ do
        simpleStatus second `shouldBe` simpleStatus first
        simpleBody second `shouldBe` simpleBody first

    it "keeps each user's keys separate" $ do
      -- The test client keeps a cookie jar like a browser, so alice finishes
      -- before bob logs in (his cookie would replace hers in the jar).
      alice <- loginAs "alice"
      keyedTransfer alice "same-key" (transfer "acme-ops" "acme-payroll" 100) `shouldRespondWith` 201
      bob <- loginAs "bob"
      -- Same key, different user and request: a new transfer, not a 409.
      keyedTransfer bob "same-key" (transfer "globex-ops" "globex-payroll" 100) `shouldRespondWith` 201

    it "rejects a key with spaces" $ do
      cookie <- loginAs "alice"
      keyedTransfer cookie "two words" (transfer "acme-ops" "acme-payroll" 1) `shouldRespondWith` errorCode 400 "invalid_idempotency_key"

  describe "login limits" $ with demoApp $ do
    it "refuses a username after 5 wrong passwords, even with the right one" $ do
      mapM_ (const (login "alice" "wrong-password")) [1 .. 5 :: Int]
      response <- login "alice" "test-password"
      liftIO $ lookup "Retry-After" (simpleHeaders response) `shouldSatisfy` (/= Nothing)
      pure response `shouldRespondWith` errorCode 429 "too_many_attempts"

    it "doesn't lock out other users" $ do
      mapM_ (const (login "alice" "wrong-password")) [1 .. 5 :: Int]
      login "bob" "test-password" `shouldRespondWith` 200

  describe "login limits behind a trusted proxy" $ with (demoAppWith True) $
    it "counts failures per client address from X-Forwarded-For" $ do
      -- 30 failures from one client (the last address is what our proxy saw).
      mapM_ (\i -> loginFrom "203.0.113.1" ("user" <> T.pack (show i)) "wrong") [1 .. 30 :: Int]
      loginFrom "203.0.113.1" "alice" "test-password" `shouldRespondWith` errorCode 429 "too_many_attempts"
      -- A different client behind the same proxy is unaffected.
      loginFrom "203.0.113.2" "alice" "test-password" `shouldRespondWith` 200

  describe "login limits without a trusted proxy" $ with demoApp $
    it "ignores X-Forwarded-For, so a faked header can't dodge the limit" $ do
      mapM_ (\i -> loginFrom (T.pack ("198.51.100." <> show i)) ("user" <> T.pack (show i)) "wrong") [1 .. 30 :: Int]
      loginFrom "198.51.100.200" "alice" "test-password" `shouldRespondWith` errorCode 429 "too_many_attempts"

  describe "account owners" $ with demoApp $ do
    it "lets an admin give an account a new owner, who can then see it" $ do
      admin <- loginAs "admin"
      putAs admin "/api/accounts/globex-ops/owner" "{\"owner\": \"alice\"}" `shouldRespondWith` 200
      alice <- loginAs "alice"
      getAs alice "/api/accounts/globex-ops" `shouldRespondWith` 200

    it "is for admins only" $ do
      alice <- loginAs "alice"
      putAs alice "/api/accounts/globex-ops/owner" "{\"owner\": \"alice\"}" `shouldRespondWith` errorCode 403 "forbidden"

    it "never gives the external account an owner" $ do
      admin <- loginAs "admin"
      putAs admin "/api/accounts/external/owner" "{\"owner\": \"alice\"}" `shouldRespondWith` errorCode 422 "system_account"

    it "needs an existing account and an existing user" $ do
      admin <- loginAs "admin"
      putAs admin "/api/accounts/nobody/owner" "{\"owner\": \"alice\"}" `shouldRespondWith` errorCode 404 "unknown_account"
      putAs admin "/api/accounts/acme-ops/owner" "{\"owner\": \"nobody\"}" `shouldRespondWith` errorCode 404 "unknown_user"

  describe "browser safety" $ with demoApp $ do
    it "refuses request bodies that aren't sent as JSON" $ do
      cookie <- loginAs "alice"
      -- What a form on another website would send: no application/json.
      request methodPost "/api/transfers" [("Content-Type", "text/plain"), ("Cookie", cookie)] (transfer "acme-ops" "acme-payroll" 1)
        `shouldRespondWith` errorCode 415 "unsupported_media_type"

    it "tells browsers and proxies not to store responses" $ do
      response <- get "/api/health"
      liftIO $ lookup "Cache-Control" (simpleHeaders response) `shouldBe` Just "no-store"

    it "marks the cookie Secure when the request came over HTTPS, and not otherwise" $ do
      let body = encode (object ["username" .= ("alice" :: Text), "password" .= ("test-password" :: Text)])
      overHttps <- request methodPost "/api/login" [("Content-Type", "application/json"), ("X-Forwarded-Proto", "https")] body
      overHttp <- login "alice" "test-password"
      liftIO $ do
        lookup "Set-Cookie" (simpleHeaders overHttps) `shouldSatisfy` maybe False (BS.isInfixOf "Secure")
        lookup "Set-Cookie" (simpleHeaders overHttp) `shouldSatisfy` maybe False (not . BS.isInfixOf "Secure")

  describe "other requests" $ with demoApp $
    it "answers unknown URLs with a JSON 404" $
      get "/api/nope" `shouldRespondWith` errorCode 404 "not_found"

  describe "request size" $
    it "refuses request bodies over 64 KB" $ do
      -- hspec-wai's helpers send bodies in a way the size check can't see,
      -- so this test builds the request by hand, the way Warp would for a
      -- request whose Content-Length says 70,000 bytes. The size check runs
      -- when a handler reads the body, which happens after the login check,
      -- so it logs in first; the session's cookie jar sends the cookie on.
      application <- demoApp
      let loginRequest =
            WaiTest.SRequest
              (WaiTest.setPath defaultRequest {requestMethod = methodPost, requestHeaders = jsonType} "/api/login")
              (encode (object ["username" .= ("alice" :: Text), "password" .= ("test-password" :: Text)]))
          oversized =
            WaiTest.setPath
              defaultRequest {requestMethod = methodPost, requestHeaders = jsonType, requestBodyLength = KnownLength 70000}
              "/api/transfers"
      response <- WaiTest.runSession (WaiTest.srequest loginRequest >> WaiTest.request oversized) application
      errorCodeOf (WaiTest.simpleBody response) `shouldBe` Just "payload_too_large"

  describe "when the store crashes" $ with crashingApp $
    it "answers with a JSON 500 that doesn't leak the error's details" $ do
      cookie <- loginAs "alice"
      response <- getAs cookie "/api/accounts"
      liftIO $ do
        errorCodeOf (simpleBody response) `shouldBe` Just "internal_error"
        -- BS.isInfixOf: does the first text appear anywhere in the second?
        BL.toStrict (simpleBody response) `shouldNotSatisfy` BS.isInfixOf "internal detail"

-- Apps under test ---------------------------------------------------------------

-- | The API over fresh in-memory stores with the demo data and demo users.
demoApp :: IO Application
demoApp = demoAppWith False

-- | The same, saying whether it sits behind a trusted proxy.
demoAppWith :: Bool -> IO Application
demoAppWith trustProxy = do
  store <- newInMemoryStore
  users <- newInMemoryUserStore
  seedDemoData "test-password" store users
  app =<< newEnv store users SecureOverHttps trustProxy

-- | A working login, but a ledger store where every operation throws,
-- standing in for "the database is down".
crashingApp :: IO Application
crashingApp = do
  users <- newInMemoryUserStore
  hash <- hashPassword "test-password"
  _ <- storeCreateUser users (User (Username "alice") RoleCustomer) hash
  app =<< newEnv crashingStore users SecureOverHttps False

crashingStore :: LedgerStore
crashingStore =
  LedgerStore
    { storeOpenAccount = \_ _ _ _ -> boom
    , storeGetAccount = const boom
    , storeListAccounts = boom
    , storeListAccountsOwnedBy = const boom
    , storeSetAccountOwner = \_ _ -> boom
    , storeEntries = const boom
    , storeTransfer = \_ _ -> boom
    }
  where
    boom :: IO a
    boom = throwIO (userError "internal detail")

-- Requests ------------------------------------------------------------------------

login :: Text -> Text -> WaiSession st SResponse
login name password =
  request methodPost "/api/login" [("Content-Type", "application/json")] (encode (object ["username" .= name, "password" .= password]))

-- | A login through a proxy that reports the client's address. The first
-- address is one the client made up; the last is what our proxy saw.
loginFrom :: Text -> Text -> Text -> WaiSession st SResponse
loginFrom address name password =
  request
    methodPost
    "/api/login"
    [("Content-Type", "application/json"), ("X-Forwarded-For", encodeUtf8 ("10.9.9.9, " <> address))]
    (encode (object ["username" .= name, "password" .= password]))

-- | Log in as a demo user and return the Cookie header to send back:
-- "ledger_session=<token>". The Set-Cookie header also carries attributes
-- after a ";" (HttpOnly, Path...), which a browser doesn't send back.
loginAs :: Text -> WaiSession st BS.ByteString
loginAs name = do
  response <- login name "test-password"
  case lookup "Set-Cookie" (simpleHeaders response) of
    Just setCookie -> pure (BS.takeWhile (/= 59) setCookie) -- 59 is ';'
    Nothing -> liftIO (expectationFailure ("login as " <> show name <> " failed")) >> pure ""

getAs :: BS.ByteString -> BS.ByteString -> WaiSession st SResponse
getAs cookie path = request methodGet path [("Cookie", cookie)] ""

postAs :: BS.ByteString -> BS.ByteString -> BL.ByteString -> WaiSession st SResponse
postAs cookie path = request methodPost path (jsonHeaders cookie)

putAs :: BS.ByteString -> BS.ByteString -> BL.ByteString -> WaiSession st SResponse
putAs cookie path = request methodPut path (jsonHeaders cookie)

keyedTransfer :: BS.ByteString -> BS.ByteString -> BL.ByteString -> WaiSession st SResponse
keyedTransfer cookie key = request methodPost "/api/transfers" (("Idempotency-Key", key) : jsonHeaders cookie)

jsonType :: [Header]
jsonType = [("Content-Type", "application/json")]

jsonHeaders :: BS.ByteString -> [Header]
jsonHeaders cookie = [("Content-Type", "application/json"), ("Cookie", cookie)]

transfer :: Text -> Text -> Integer -> BL.ByteString
transfer from to cents = encode (object ["from" .= from, "to" .= to, "amountCents" .= cents])

-- Reading responses -------------------------------------------------------------------

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

-- | The "id" of every account in a JSON list of accounts.
accountIds :: BL.ByteString -> Maybe [Text]
accountIds body = do
  accounts <- decode body :: Maybe [Map.Map Text Value]
  -- traverse: run the lookup on every account; one failure fails them all.
  traverse (\a -> case Map.lookup "id" a of Just (String i) -> Just i; _ -> Nothing) accounts
