-- OverloadedStrings lets a string literal like "ok" be a Text (or a lazy
-- Text, or bytes) instead of always a String. Without it, every literal
-- would need converting with T.pack.
{-# LANGUAGE OverloadedStrings #-}

-- | The HTTP edge. Handlers run in @ReaderT Env IO@ (a simple, explicit
-- way to pass dependencies) and translate domain errors into HTTP responses
-- here, and only here.
--
-- This is the only module that knows about HTTP, JSON bodies, cookies and
-- status codes. For each request it works out WHO is asking (the session
-- cookie), checks they're ALLOWED (Ledger.Auth), turns the request into
-- domain values (TransferRequest, Amount...), calls the store, and turns the
-- result back into an HTTP response.
module Ledger.App
  ( Env (..)
  , app
  , externalAccountId
  ) where

import Control.Exception (SomeException, catch, evaluate)
import Control.Monad (forM_, unless, void)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ReaderT, asks, runReaderT)
import Control.Monad.Trans.Class (lift)
import Data.Aeson (FromJSON (..), Value, eitherDecode, encode, object, withObject, (.:), (.:?), (.=))
import qualified Data.ByteString as BS
import Data.ByteString.Builder (toLazyByteString)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
-- Qualified imports again: T.pack and TL.toStrict, so it's always clear
-- which of the two Text types a function belongs to. Scotty 0.12 uses
-- "lazy" Text (Data.Text.Lazy) in places; our code uses strict Text.
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8', encodeUtf8)
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as TLE
import Data.Time (NominalDiffTime, addUTCTime, getCurrentTime)
import Ledger.Auth
import Ledger.Money (Amount, Cents (..), formatCents, maxAmount, mkAmount)
import Ledger.Session
import Ledger.Store
import Ledger.Types
import Ledger.Validate
import Network.HTTP.Types.Header (hContentType)
import Network.HTTP.Types.Status
import Network.Wai (Application, Response, responseLBS)
import Network.Wai.Middleware.RequestSizeLimit
import System.IO (hPutStrLn, stderr)
import Web.Cookie (SetCookie (..), defaultSetCookie, parseCookies, renderSetCookie, sameSiteLax)
-- Scotty is a small web framework, similar to Express in Node.
import Web.Scotty.Trans

-- | Everything a handler needs from outside.
data Env = Env
  { envStore :: LedgerStore
  , envUsers :: UserStore
  , -- | Mark the session cookie "Secure" (sent over HTTPS only). On for any
    -- real deployment; off for http://localhost during development.
    envSecureCookies :: Bool
  }

-- | The type of every request handler.
--
-- A "type" declaration is just a nickname (an alias), like TypeScript's
-- "type Handler = ...". Read it as: a Scotty action (ActionT), whose error
-- type is lazy Text, running on top of "ReaderT Env IO".
--
-- "ReaderT Env IO" means "an IO action that can also read the Env". It's a
-- way to pass the store to every handler without adding it as an argument
-- to each one. Think of it as dependency injection built into the type.
type Handler = ActionT TL.Text (ReaderT Env IO)

-- | The account that deposits come from (see AccountKind in Ledger.Types).
externalAccountId :: AccountId
externalAccountId = AccountId "external"

-- Request bodies ------------------------------------------------------------
--
-- Each body gets a small type and a hand-written JSON parser. The parsers
-- use the "applicative style":
--   OpenAccountBody <$> o .: "id" <*> o .: "name"
-- reads as: build an OpenAccountBody from the "id" field and the "name"
-- field. If either field is missing or has the wrong type, parsing fails
-- with an error message instead of building a half-filled value.
--   o .: "x"   -> required field x
--   o .:? "x"  -> optional field x (gives a Maybe)

-- | { "username": "alice", "password": "..." }
data LoginBody = LoginBody Text Text

instance FromJSON LoginBody where
  -- withObject checks the JSON is an object {...}, then gives us "o" to read
  -- fields from. "\o -> ..." is a lambda: (o) => ...
  parseJSON = withObject "LoginBody" $ \o ->
    LoginBody <$> o .: "username" <*> o .: "password"

-- | { "id": "acme-ops", "name": "Acme Operating", "owner": "alice" }
-- "owner" is optional: it defaults to whoever is logged in.
data OpenAccountBody = OpenAccountBody Text Text (Maybe Text)

instance FromJSON OpenAccountBody where
  parseJSON = withObject "OpenAccountBody" $ \o ->
    OpenAccountBody <$> o .: "id" <*> o .: "name" <*> o .:? "owner"

-- | { "from": "acme-ops", "to": "acme-payroll", "amountCents": 1500, "memo": "..." }
data TransferBody = TransferBody Text Text Integer (Maybe Text)

instance FromJSON TransferBody where
  parseJSON = withObject "TransferBody" $ \o ->
    TransferBody <$> o .: "from" <*> o .: "to" <*> o .: "amountCents" <*> o .:? "memo"

-- | { "to": "acme-ops", "amountCents": 100000 }
data DepositBody = DepositBody Text Integer

instance FromJSON DepositBody where
  parseJSON = withObject "DepositBody" $ \o ->
    DepositBody <$> o .: "to" <*> o .: "amountCents"

-- Application ---------------------------------------------------------------

-- | Build the web application. Main.hs passes it to the Warp web server.
--
-- runReaderT supplies the Env to every handler. "(`runReaderT` env)" is a
-- section: a function waiting for its first argument, i.e.
--   \action -> runReaderT action env
app :: Env -> IO Application
-- "f . g" runs g first, then f: limit body size, then catch crashes. The
-- outermost wrapper sees every request first and every response last.
app env = jsonErrorsFor500 . limitBodySize <$> scottyAppT (`runReaderT` env) routes

-- | Refuse request bodies over 64 KB with a JSON 413. Without a limit,
-- Scotty reads the whole body into memory, so one huge request could use up
-- the server's memory. No real request here is anywhere near that size.
limitBodySize :: Application -> Application
limitBodySize =
  requestSizeLimitMiddleware
    ( setOnLengthExceeded (\_limit _inner _request respond -> respond tooLarge) $
        setMaxLengthForRequest (\_request -> pure (Just 65536)) defaultRequestSizeLimitSettings
    )
  where
    tooLarge = jsonErrorResponse status413 "payload_too_large" "Request body must be at most 64 KB."

-- | If a handler crashes (the database is down, a bug...), answer with the
-- same JSON error shape as every other error instead of a plain-text 500,
-- and log the details on the server, never in the response.
--
-- An Application is a function "request -> respond -> IO ResponseReceived",
-- so wrapping one is just writing another function that calls it inside
-- "catch", Haskell's try/catch.
jsonErrorsFor500 :: Application -> Application
jsonErrorsFor500 inner httpRequest respond =
  inner httpRequest respond `catch` \e -> do
    -- The type annotation says which exceptions to catch: all of them.
    hPutStrLn stderr ("Unhandled error: " <> show (e :: SomeException))
    respond (jsonErrorResponse status500 "internal_error" "Something went wrong on our side. Please try again.")

-- | A complete JSON error response, for code outside Scotty's handlers.
-- Same { "error", "message" } shape as failWith below.
jsonErrorResponse :: Status -> Text -> Text -> Response
jsonErrorResponse st code msg =
  responseLBS st [(hContentType, "application/json")] (encode (object ["error" .= code, "message" .= msg]))

-- | The routing table, like app.get(...) / app.post(...) in Express.
-- Each route is a "do" block: a sequence of steps that ends in a response.
routes :: ScottyT TL.Text (ReaderT Env IO) ()
routes = do
  -- "object [...]" builds a JSON object; ".=" pairs a key with a value.
  -- ("ok" :: Text) says which string type we mean, since
  -- OverloadedStrings makes the literal ambiguous here.
  get "/api/health" $ json (object ["status" .= ("ok" :: Text)])

  -- Logging in and out ----------------------------------------------------

  post "/api/login" $ do
    LoginBody rawName password <- decodeBody
    users <- lift (asks envUsers)
    found <- liftIO (storeFindUser users (Username (T.toLower (T.strip rawName))))
    loggedIn <- liftIO $ case found of
      Just (user, hash) -> pure (if passwordMatches password hash then Just user else Nothing)
      Nothing -> do
        -- No such user. Hash the password anyway and throw the result away,
        -- so this answer takes as long as a wrong password would. Otherwise
        -- the response time would reveal which usernames exist.
        -- "evaluate" forces the (lazy) hash to actually be computed.
        void (evaluate . T.length =<< hashPassword password)
        pure Nothing
    case loggedIn of
      -- The same answer for "no such user" and "wrong password", for the
      -- same reason.
      Nothing -> failWith status401 "invalid_credentials" "Wrong username or password."
      Just user -> do
        (token, tokenHash) <- liftIO newSessionToken
        now <- liftIO getCurrentTime
        liftIO (storeCreateSession users tokenHash (userName user) (addUTCTime sessionLifetime now))
        secure <- lift (asks envSecureCookies)
        setHeader "Set-Cookie" (sessionCookie secure token sessionLifetime)
        json (userJson user)

  post "/api/logout" $ do
    users <- lift (asks envUsers)
    mToken <- sessionToken
    -- forM_ over a Maybe runs the action only if there's a token.
    forM_ mToken (liftIO . storeDeleteSession users . hashToken)
    secure <- lift (asks envSecureCookies)
    -- An empty cookie that expires immediately makes the browser drop it.
    setHeader "Set-Cookie" (sessionCookie secure "" 0)
    status status204

  get "/api/me" $ requireUser >>= json . userJson

  -- Accounts ----------------------------------------------------------------

  get "/api/accounts" $ do
    -- Every route below starts by finding out who's asking. requireUser
    -- stops the request with a 401 if nobody is logged in.
    user <- requireUser
    -- How a handler reaches the store:
    --   asks envStore  -> read the store out of the Env
    --   lift           -> move that from the ReaderT layer up into Scotty
    --   liftIO         -> run a plain IO action inside the handler
    -- These "lifts" are how Haskell mixes several capabilities (web, reader,
    -- IO) in one function. You'll see the same three-line shape below.
    store <- lift (asks envStore)
    ledgerAccounts <- liftIO (storeListAccounts store)
    -- A list comprehension with a filter: only the accounts this user may
    -- see. Customers get their own; admins get everything.
    json [accountJson a b | (a, b) <- ledgerAccounts, canView user a]

  post "/api/accounts" $ do
    user <- requireUser
    -- Pattern match on the parsed body to name its fields at once.
    OpenAccountBody rawId rawName rawOwner <- decodeBody
    -- Check the text before it goes anywhere near the store.
    aid <- requireValid "invalid_account_id" (validAccountId rawId)
    name <- requireValid "invalid_account_name" (validAccountName rawName)
    -- No owner in the body means "for me".
    let owner = maybe (userName user) (Username . T.toLower . T.strip) rawOwner
    unless (canOpenAccountFor user owner) $
      forbidden "You can only open accounts for yourself."
    -- An admin opening an account for someone else: that someone must exist.
    users <- lift (asks envUsers)
    ownerExists <- liftIO (storeFindUser users owner)
    case ownerExists of
      Nothing -> failWith status404 "unknown_user" "No such user." >> finish
      Just _ -> pure ()
    store <- lift (asks envStore)
    result <- liftIO (storeOpenAccount store (AccountId aid) name Customer (Just owner))
    case result of
      Left (AccountAlreadyExists _) -> failWith status409 "account_exists" "An account with that id already exists."
      -- ">>" runs one action, then the next: set status 201, then send JSON.
      Right account -> status status201 >> json (accountJson account 0)

  get "/api/accounts/:id" $ do
    user <- requireUser
    -- param "id" reads the ":id" part of the URL.
    (account, bal) <- requireVisibleAccount user =<< param "id"
    json (accountJson account bal)

  get "/api/accounts/:id/entries" $ do
    user <- requireUser
    (account, _) <- requireVisibleAccount user =<< param "id"
    store <- lift (asks envStore)
    found <- liftIO (storeEntries store (accountId account))
    -- maybe default f m: Nothing -> the 404; Just entries -> json entries.
    maybe (failWith status404 "unknown_account" "No such account.") json found

  -- Moving money ------------------------------------------------------------

  post "/api/deposits" $ do
    user <- requireUser
    unless (canDeposit user) $
      forbidden "Only admins can make deposits."
    DepositBody to cents <- decodeBody
    -- Validate the raw number into an Amount right at the edge. After this
    -- line, "amount" is guaranteed valid (see Ledger.Money).
    amount <- requireAmount cents
    -- A deposit is just a transfer from the external account.
    runTransfer user (TransferRequest externalAccountId (AccountId to) amount "Deposit")

  post "/api/transfers" $ do
    user <- requireUser
    TransferBody from to cents rawMemo <- decodeBody
    amount <- requireAmount cents
    -- fromMaybe "" rawMemo: use the memo if one was sent, otherwise "".
    memo <- requireValid "invalid_memo" (validMemo (fromMaybe "" rawMemo))
    -- The sender must be an account this user can see (404 otherwise, so
    -- nobody learns which accounts exist) AND send from (403).
    (fromAccount, _) <- requireVisibleAccount user from
    unless (canSendFrom user fromAccount) $
      forbidden "You can only send money from your own accounts."
    runTransfer user (TransferRequest (AccountId from) (AccountId to) amount memo)

  -- Any URL that matched none of the routes above: a JSON 404 like every
  -- other error, instead of Scotty's default HTML page.
  notFound $ failWith status404 "not_found" "No such endpoint."

-- | Shared by deposits and transfers: read the optional Idempotency-Key
-- header, run the transfer, and send back the result.
runTransfer :: User -> TransferRequest -> Handler ()
runTransfer user req = do
  -- header returns "Maybe (lazy Text)": Nothing if the header is absent.
  -- "fmap f <$> action" applies f inside the Maybe inside the action's
  -- result: here, convert lazy Text to strict Text.
  rawKey <- fmap TL.toStrict <$> header "Idempotency-Key"
  -- traverse runs the check only when a key was sent: Nothing stays
  -- Nothing, Just k becomes Just (the checked key), or the request stops
  -- with a 400.
  key <- traverse (requireValid "invalid_idempotency_key" . validIdempotencyKey) rawKey
  -- Keys are per user: "alice:payroll-1" and "bob:payroll-1" are different
  -- keys. Otherwise one user's key could replay another user's transfer.
  let Username name = userName user
      scopedKey = IdempotencyKey . ((name <> ":") <>) <$> key
  store <- lift (asks envStore)
  result <- liftIO (storeTransfer store scopedKey req)
  case result of
    Right transfer -> status status201 >> json transfer
    Left err -> transferError err

-- | The one place where business errors become HTTP.
--
-- A case over every TransferError constructor. If a new kind of error is
-- added to Ledger.Types and not handled here, -Wall warns about it, so the
-- compiler points you straight to this function.
transferError :: TransferError -> Handler ()
transferError err = case err of
  -- Patterns can reach inside nested values: "UnknownAccount (AccountId aid)"
  -- unwraps both layers at once, naming the Text inside "aid".
  -- "<>" joins two Texts, like + on strings in TypeScript.
  UnknownAccount (AccountId aid) -> failWith status404 "unknown_account" ("No account " <> aid <> ".")
  SameAccount -> failWith status422 "same_account" "Source and destination must differ."
  InsufficientFunds avail req ->
    failWith status422 "insufficient_funds" $
      "Insufficient funds: " <> formatCents avail <> " available, " <> formatCents req <> " requested."
  IdempotencyKeyReused ->
    failWith status409 "idempotency_key_reused" "This Idempotency-Key was already used with a different request."

-- Helpers -------------------------------------------------------------------

-- | Who is logged in, or reply 401 and stop.
requireUser :: Handler User
requireUser = do
  mToken <- sessionToken
  users <- lift (asks envUsers)
  now <- liftIO getCurrentTime
  -- "maybe (pure Nothing) f m": no cookie -> Nothing; a cookie -> look it up.
  mUser <- maybe (pure Nothing) (\token -> liftIO (storeFindSession users (hashToken token) now)) mToken
  maybe (failWith status401 "unauthorized" "Please log in." >> finish) pure mUser

-- | The account with this id, if this user may see it. Otherwise reply 404,
-- the same as for an account that doesn't exist, so the answer never
-- reveals that someone else's account is there.
requireVisibleAccount :: User -> Text -> Handler (Account, Cents)
requireVisibleAccount user aid = do
  store <- lift (asks envStore)
  found <- liftIO (storeGetAccount store (AccountId aid))
  case found of
    Just (account, bal) | canView user account -> pure (account, bal)
    _ -> failWith status404 "unknown_account" ("No account " <> aid <> ".") >> finish

-- | Reply 403 and stop.
forbidden :: Text -> Handler ()
forbidden msg = failWith status403 "forbidden" msg >> finish

-- | The session token from the request's Cookie header, if there is one.
sessionToken :: Handler (Maybe Text)
sessionToken = do
  mCookieHeader <- header "Cookie"
  -- A do block in Maybe: any missing piece makes the result Nothing.
  pure $ do
    cookieHeader <- mCookieHeader
    value <- lookup sessionCookieName (parseCookies (encodeUtf8 (TL.toStrict cookieHeader)))
    -- decodeUtf8' returns Left for bytes that aren't valid UTF-8, instead
    -- of crashing; "either (const Nothing) Just" turns that into Nothing.
    either (const Nothing) Just (decodeUtf8' value)

sessionCookieName :: BS.ByteString
sessionCookieName = "ledger_session"

-- | The Set-Cookie header value for a session token.
--
--   HttpOnly  JavaScript can't read it, so an XSS bug can't steal it.
--   SameSite=Lax  other websites can't make the browser send it with their
--             POST requests (protection against cross-site request forgery).
--   Secure    HTTPS only (see envSecureCookies).
--   Max-Age   when the browser should forget it.
sessionCookie :: Bool -> Text -> NominalDiffTime -> TL.Text
sessionCookie secure token maxAge =
  TLE.decodeUtf8 . toLazyByteString . renderSetCookie $
    defaultSetCookie
      { setCookieName = sessionCookieName
      , setCookieValue = encodeUtf8 token
      , setCookiePath = Just "/"
      , setCookieHttpOnly = True
      , setCookieSameSite = Just sameSiteLax
      , setCookieSecure = secure
      , -- realToFrac converts between the two time-length types.
        setCookieMaxAge = Just (realToFrac maxAge)
      }

-- | Parse the request body as JSON, or reply 400 and stop.
--
-- "FromJSON a => Handler a" reads as: for ANY type a that has a JSON parser,
-- this handler produces an a. The part before "=>" is a constraint, like a
-- TypeScript generic with a bound: <A extends FromJSON>. The caller decides
-- which a it wants (OpenAccountBody, TransferBody...) by how it uses it.
decodeBody :: FromJSON a => Handler a
decodeBody = do
  payload <- body
  case eitherDecode payload of
    Right a -> pure a
    -- "finish" stops the handler here, like an early return. Without it the
    -- code would need a value of type a to continue, and there isn't one.
    Left e -> failWith status400 "bad_request" (T.pack e) >> finish

-- | Turn a raw number from JSON into an Amount, or reply 400 and stop.
requireAmount :: Integer -> Handler Amount
requireAmount cents = case mkAmount cents of
  Just a -> pure a
  Nothing ->
    failWith status400 "invalid_amount" ("Amount must be a positive number of cents, at most " <> formatCents (Cents maxAmount) <> ".")
      >> finish

-- | Use a checked value, or reply 400 with the check's message and stop.
requireValid :: Text -> Either Text a -> Handler a
requireValid code = either (\msg -> failWith status400 code msg >> finish) pure

-- | Send an error response: { "error": "<code>", "message": "<text>" }.
-- The front end shows "message"; code can branch on "error".
failWith :: Status -> Text -> Text -> Handler ()
failWith st code msg = status st >> json (object ["error" .= code, "message" .= msg])

-- | The JSON shape of an account, including its balance. "owner" is null
-- for system accounts.
accountJson :: Account -> Cents -> Value
accountJson a bal =
  object
    [ "id" .= accountId a
    , "name" .= accountName a
    , "kind" .= accountKind a
    , "owner" .= accountOwner a
    , "balanceCents" .= bal
    ]

-- | { "username": "alice", "role": "customer" }
userJson :: User -> Value
userJson user =
  object
    [ "username" .= userName user
    , "role" .= (case userRole user of RoleCustomer -> "customer"; RoleAdmin -> "admin" :: Text)
    ]
