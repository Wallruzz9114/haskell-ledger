-- OverloadedStrings lets a string literal like "ok" be a Text (or a lazy
-- Text, or bytes) instead of always a String. Without it, every literal
-- would need converting with T.pack.
{-# LANGUAGE OverloadedStrings #-}

-- | The HTTP edge. Handlers run in @ReaderT Env IO@ (a simple, explicit
-- way to pass dependencies) and translate domain errors into HTTP responses
-- here, and only here.
--
-- This is the only module that knows about HTTP, JSON bodies and status
-- codes. It turns requests into domain values (TransferRequest, Amount...),
-- calls the store, and turns the results back into HTTP responses.
module Ledger.App
  ( Env (..)
  , app
  , externalAccountId
  ) where

import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ReaderT, asks, runReaderT)
import Control.Monad.Trans.Class (lift)
import Data.Aeson (FromJSON (..), Value, eitherDecode, object, withObject, (.:), (.:?), (.=))
import Data.Maybe (fromMaybe)
import Data.Text (Text)
-- Qualified imports again: T.pack and TL.toStrict, so it's always clear
-- which of the two Text types a function belongs to. Scotty 0.12 uses
-- "lazy" Text (Data.Text.Lazy) in places; our code uses strict Text.
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import Ledger.Money (Amount, Cents, formatCents, mkAmount)
import Ledger.Store
import Ledger.Types
import Network.HTTP.Types.Status
import Network.Wai (Application)
-- Scotty is a small web framework, similar to Express in Node.
import Web.Scotty.Trans

-- | Everything a handler needs from outside: for now, just the store.
-- Adding a logger or config later means adding a field here.
newtype Env = Env {envStore :: LedgerStore}

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

-- | { "id": "acme-ops", "name": "Acme Operating" }
data OpenAccountBody = OpenAccountBody Text Text

instance FromJSON OpenAccountBody where
  -- withObject checks the JSON is an object {...}, then gives us "o" to read
  -- fields from. "\o -> ..." is a lambda: (o) => ...
  parseJSON = withObject "OpenAccountBody" $ \o ->
    OpenAccountBody <$> o .: "id" <*> o .: "name"

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
app env = scottyAppT (`runReaderT` env) routes

-- | The routing table, like app.get(...) / app.post(...) in Express.
-- Each route is a "do" block: a sequence of steps that ends in a response.
routes :: ScottyT TL.Text (ReaderT Env IO) ()
routes = do
  -- "object [...]" builds a JSON object; ".=" pairs a key with a value.
  -- ("ok" :: Text) says which string type we mean, since
  -- OverloadedStrings makes the literal ambiguous here.
  get "/api/health" $ json (object ["status" .= ("ok" :: Text)])

  get "/api/accounts" $ do
    -- How a handler reaches the store:
    --   asks envStore  -> read the store out of the Env
    --   lift           -> move that from the ReaderT layer up into Scotty
    --   liftIO         -> run a plain IO action inside the handler
    -- These "lifts" are how Haskell mixes several capabilities (web, reader,
    -- IO) in one function. You'll see the same three-line shape below.
    store <- lift (asks envStore)
    ledgerAccounts <- liftIO (storeListAccounts store)
    -- List comprehension (see listAccounts in Ledger.Core) building a JSON
    -- value for each (account, balance) pair.
    json [accountJson a b | (a, b) <- ledgerAccounts]

  post "/api/accounts" $ do
    -- Pattern match on the parsed body to name its two fields at once.
    OpenAccountBody aid name <- decodeBody
    store <- lift (asks envStore)
    result <- liftIO (storeOpenAccount store (AccountId aid) name Customer)
    case result of
      Left (AccountAlreadyExists _) -> failWith status409 "account_exists" "An account with that id already exists."
      -- ">>" runs one action, then the next: set status 201, then send JSON.
      Right account -> status status201 >> json (accountJson account 0)

  get "/api/accounts/:id" $ do
    -- param "id" reads the ":id" part of the URL.
    -- "AccountId <$> param "id"" wraps the result in AccountId.
    aid <- AccountId <$> param "id"
    store <- lift (asks envStore)
    found <- liftIO (storeGetAccount store aid)
    case found of
      Nothing -> failWith status404 "unknown_account" "No such account."
      Just (account, bal) -> json (accountJson account bal)

  get "/api/accounts/:id/entries" $ do
    aid <- AccountId <$> param "id"
    store <- lift (asks envStore)
    found <- liftIO (storeEntries store aid)
    -- maybe default f m: Nothing -> the 404; Just entries -> json entries.
    maybe (failWith status404 "unknown_account" "No such account.") json found

  post "/api/deposits" $ do
    DepositBody to cents <- decodeBody
    -- Validate the raw number into an Amount right at the edge. After this
    -- line, "amount" is guaranteed positive (see Ledger.Money).
    amount <- requireAmount cents
    -- A deposit is just a transfer from the external account.
    runTransfer (TransferRequest externalAccountId (AccountId to) amount "Deposit")

  post "/api/transfers" $ do
    TransferBody from to cents memo <- decodeBody
    amount <- requireAmount cents
    -- fromMaybe "" memo: use the memo if one was sent, otherwise "".
    runTransfer (TransferRequest (AccountId from) (AccountId to) amount (fromMaybe "" memo))

-- | Shared by deposits and transfers: read the optional Idempotency-Key
-- header, run the transfer, and send back the result.
runTransfer :: TransferRequest -> Handler ()
runTransfer req = do
  -- header returns "Maybe (lazy Text)": Nothing if the header is absent.
  -- "fmap f <$> action" applies f inside the Maybe inside the action's
  -- result: convert to strict Text, then wrap in IdempotencyKey.
  key <- fmap (IdempotencyKey . TL.toStrict) <$> header "Idempotency-Key"
  store <- lift (asks envStore)
  result <- liftIO (storeTransfer store key req)
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
  Nothing -> failWith status400 "invalid_amount" "Amount must be a positive number of cents." >> finish

-- | Send an error response: { "error": "<code>", "message": "<text>" }.
-- The front end shows "message"; code can branch on "error".
failWith :: Status -> Text -> Text -> Handler ()
failWith st code msg = status st >> json (object ["error" .= code, "message" .= msg])

-- | The JSON shape of an account, including its balance.
accountJson :: Account -> Cents -> Value
accountJson a bal =
  object
    [ "id" .= accountId a
    , "name" .= accountName a
    , "kind" .= accountKind a
    , "balanceCents" .= bal
    ]
