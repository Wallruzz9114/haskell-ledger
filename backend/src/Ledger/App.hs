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
  , CookiePolicy (..)
  , newEnv
  , app
  , externalAccountId
  ) where

import Control.Exception (SomeException, catch, evaluate)
import Control.Monad (forM_, unless, void, when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ReaderT, asks, runReaderT)
import Control.Monad.Trans.Class (lift)
import Data.Aeson (FromJSON (..), eitherDecode, encode, object, (.=))
import qualified Data.ByteString as BS
import Data.ByteString.Builder (toLazyByteString)
import Data.Either (fromRight)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
-- Qualified imports again: T.pack and TL.toStrict, so it's always clear
-- which of the two Text types a function belongs to. Scotty 0.12 uses
-- "lazy" Text (Data.Text.Lazy) in places; our code uses strict Text.
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8', encodeUtf8)
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as TLE
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Time (Day, NominalDiffTime, UTCTime (..), addUTCTime, diffUTCTime, fromGregorianValid, getCurrentTime, showGregorian)
import Text.Read (readMaybe)
import Ledger.Api
import Ledger.Auth
import Ledger.Reports
import Ledger.Money (Amount, Cents (..), formatCents, maxAmount, mkAmount)
import Ledger.Session
import Ledger.Store
import Ledger.Throttle
import Ledger.Types
import Ledger.Validate
import Network.HTTP.Types.Header (hContentType)
import Network.HTTP.Types.Status
import Network.Socket (SockAddr (..), hostAddress6ToTuple, hostAddressToTuple)
import Network.Wai (Application, Request, Response, isSecure, remoteHost, requestHeaders, responseLBS)
import Network.Wai.Middleware.AddHeaders (addHeaders)
import Network.Wai.Middleware.RequestSizeLimit
import System.IO (hPutStrLn, stderr)
import Web.Cookie (SetCookie (..), defaultSetCookie, parseCookies, renderSetCookie, sameSiteLax)
-- Scotty is a small web framework, similar to Express in Node.
import Web.Scotty.Trans

-- | Everything a handler needs from outside.
data Env = Env
  { envStore :: LedgerStore
  , envUsers :: UserStore
  , envCookiePolicy :: CookiePolicy
  , -- | Failed-login counts and the limit on password checks at once.
    envLoginGuard :: LoginGuard
  , -- | Is the server behind a reverse proxy we trust? Then the client's
    -- address comes from the proxy's X-Forwarded-For header; otherwise
    -- every user would seem to share the proxy's address, and one person's
    -- failed logins could lock everyone out.
    envTrustProxy :: Bool
  }

-- | When to mark the session cookie "Secure" (sent over HTTPS only).
data CookiePolicy
  = -- | Whenever the request came over HTTPS, directly or through a proxy
    -- that says so (X-Forwarded-Proto: https). The default: a real
    -- deployment behind HTTPS gets Secure cookies without anyone having to
    -- remember a setting, and http://localhost still works.
    SecureOverHttps
  | SecureAlways
  | SecureNever

-- | An Env with a fresh login guard allowing 2 password checks at once.
-- Each check holds a CPU core for ~50 ms, so a small number keeps logins
-- from ever taking over the whole server.
newEnv :: LedgerStore -> UserStore -> CookiePolicy -> Bool -> IO Env
newEnv store users policy trustProxy = do
  guard <- newLoginGuard 2
  pure (Env store users policy guard trustProxy)

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
-- The shape of each request body (LoginRequest, TransferRequestBody...) is
-- defined in Ledger.Api, which also generates the matching TypeScript types
-- for the front end. Each handler below parses its body with decodeBody and
-- takes the fields apart with a record pattern, e.g.
--   LoginRequest {loginRequestUsername = rawName, ...} <- decodeBody
-- which names the fields it needs.

-- Application ---------------------------------------------------------------

-- | Build the web application. Main.hs passes it to the Warp web server.
--
-- runReaderT supplies the Env to every handler. "(`runReaderT` env)" is a
-- section: a function waiting for its first argument, i.e.
--   \action -> runReaderT action env
app :: Env -> IO Application
-- "f . g" runs g first, then f: limit body size, then catch crashes. The
-- outermost wrapper sees every request first and every response last.
app env = jsonErrorsFor500 . noStore . limitBodySize <$> scottyAppT (`runReaderT` env) routes

-- | Tell browsers and proxies never to keep a copy of any response. They
-- carry account balances and other private data.
noStore :: Application -> Application
noStore = addHeaders [("Cache-Control", "no-store")]

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
  responseLBS st [(hContentType, "application/json")] (encode (ErrorBody code msg))

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
    LoginRequest {loginRequestUsername = rawName, loginRequestPassword = password} <- decodeBody
    let name = T.toLower (T.strip rawName)
    address <- clientAddress
    guard <- lift (asks envLoginGuard)
    now <- liftIO getCurrentTime
    -- Too many recent failures for this username or from this address?
    -- Refuse BEFORE doing any expensive password work.
    blocked <- liftIO (loginBlockedUntil guard now name address)
    forM_ blocked $ \retryAt -> do
      -- ceiling: round up to whole seconds for the Retry-After header.
      setHeader "Retry-After" (TL.pack (show (ceiling (diffUTCTime retryAt now) :: Integer)))
      failWith status429 "too_many_attempts" "Too many failed logins. Please wait and try again." >> finish
    users <- lift (asks envUsers)
    -- Check the password in one of the limited slots. Nothing = all busy.
    checked <- liftIO . withHashSlot guard $ do
      found <- storeFindUser users (Username name)
      case found of
        -- "evaluate" makes the (lazy) check actually run here, inside the
        -- slot, rather than later when the result is first looked at.
        Just (user, hash) -> do
          ok <- evaluate (passwordMatches password hash)
          pure (if ok then Just user else Nothing)
        Nothing -> do
          -- No such user. Hash the password anyway and throw the result
          -- away, so this answer takes as long as a wrong password would.
          -- Otherwise the response time would reveal which usernames exist.
          void (evaluate . T.length =<< hashPassword password)
          pure Nothing
    case checked of
      Nothing -> do
        setHeader "Retry-After" "1"
        failWith status503 "login_busy" "The server is busy checking other logins. Please try again in a moment."
      -- The same answer for "no such user" and "wrong password", for the
      -- same reason.
      Just Nothing -> do
        liftIO (loginFailed guard now name address)
        failWith status401 "invalid_credentials" "Wrong username or password."
      Just (Just user) -> do
        liftIO (loginSucceeded guard name)
        (token, tokenHash) <- liftIO newSessionToken
        liftIO (storeCreateSession users tokenHash (userName user) (addUTCTime sessionLifetime now))
        secure <- cookieShouldBeSecure
        setHeader "Set-Cookie" (sessionCookie secure token sessionLifetime)
        json (userView user)

  post "/api/logout" $ do
    users <- lift (asks envUsers)
    mToken <- sessionToken
    -- forM_ over a Maybe runs the action only if there's a token.
    forM_ mToken (liftIO . storeDeleteSession users . hashToken)
    secure <- cookieShouldBeSecure
    -- An empty cookie that expires immediately makes the browser drop it.
    setHeader "Set-Cookie" (sessionCookie secure "" 0)
    status status204

  get "/api/me" $ requireUser >>= json . userView

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
    -- Admins get every account; customers only their own, filtered by the
    -- store (in Postgres, by the database) rather than here.
    ledgerAccounts <-
      liftIO $
        if canSeeAllAccounts user
          then storeListAccounts store
          else storeListAccountsOwnedBy store (userName user)
    -- canView again, as a second line of defence: a list comprehension
    -- with a filter.
    json [accountView a b | (a, b) <- ledgerAccounts, canView user a]

  post "/api/accounts" $ do
    user <- requireUser
    -- Pattern match on the parsed body to name its fields at once.
    OpenAccountRequest {openAccountRequestId = rawId, openAccountRequestName = rawName, openAccountRequestOwner = rawOwner} <- decodeBody
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
      Right account -> status status201 >> json (accountView account 0)

  get "/api/accounts/:id" $ do
    user <- requireUser
    -- param "id" reads the ":id" part of the URL.
    (account, bal) <- requireVisibleAccount user =<< param "id"
    json (accountView account bal)

  -- Give an account an owner. Admins only. Accounts opened before users
  -- existed have no owner, which leaves them unusable: nobody can send from
  -- them and customers can't see them. This is how an admin fixes that (or
  -- moves an account to another user).
  put "/api/accounts/:id/owner" $ do
    user <- requireUser
    unless (canAssignOwners user) $
      forbidden "Only admins can change an account's owner."
    SetOwnerRequest {setOwnerRequestOwner = rawOwner} <- decodeBody
    aid <- param "id"
    let owner = Username (T.toLower (T.strip rawOwner))
    users <- lift (asks envUsers)
    ownerExists <- liftIO (storeFindUser users owner)
    when (null ownerExists) $
      failWith status404 "unknown_user" "No such user." >> finish
    store <- lift (asks envStore)
    found <- liftIO (storeGetAccount store (AccountId aid))
    case found of
      Nothing -> failWith status404 "unknown_account" ("No account " <> aid <> ".")
      Just (account, _)
        | accountKind account /= Customer ->
            failWith status422 "system_account" "System accounts like \"external\" can't have an owner."
      Just (_, bal) -> do
        _ <- liftIO (storeSetAccountOwner store (AccountId aid) owner)
        updated <- liftIO (storeGetAccount store (AccountId aid))
        -- maybe default f m: fall back to the balance we already have.
        maybe (pure ()) (\(account, b) -> json (accountView account b)) updated
        when (null updated) $ json (object ["id" .= aid, "balanceCents" .= bal])

  get "/api/accounts/:id/entries" $ do
    user <- requireUser
    (account, _) <- requireVisibleAccount user =<< param "id"
    store <- lift (asks envStore)
    found <- liftIO (storeEntries store (accountId account))
    -- maybe default f m: Nothing -> the 404; Just entries -> json entries.
    maybe (failWith status404 "unknown_account" "No such account.") json found

  -- Overview: the dashboard and the transactions page ----------------------

  -- ?month=2026-09 (default: this month) and ?days=90 (how far back the
  -- balance chart goes, 7 to 366).
  get "/api/dashboard" $ do
    user <- requireUser
    today <- liftIO (utctDay <$> getCurrentTime)
    month <- maybe (pure today) (requireValid "invalid_month" . parseMonth) =<< optionalParam "month"
    days <- maybe (pure 90) (requireValid "invalid_days" . parseBounded 7 366 "days") =<< optionalParam "days"
    (mine, names, entries) <- overviewData user
    let total = sum (map snd mine)
        report = dashboard (Set.fromList (map (accountId . fst) mine)) total entries today days month
        party (PartyTotal aid amount) = PartyView (idText aid) (nameIn names aid) (centsOf amount)
    json
      DashboardView
        { dashboardViewTotalBalanceCents = centsOf total
        , -- showGregorian gives "2026-09-01"; the first 7 characters are the month.
          dashboardViewMonth = T.take 7 (T.pack (showGregorian month))
        , dashboardViewSeries = [BalancePointView d (centsOf b) | BalancePoint d b <- dashSeries report]
        , dashboardViewMoneyInCents = centsOf (dashMoneyIn report)
        , dashboardViewMoneyOutCents = centsOf (dashMoneyOut report)
        , dashboardViewTopSources = map party (dashTopSources report)
        , dashboardViewTopSpending = map party (dashTopSpending report)
        }

  -- ?q=words to search, ?account=acme-ops, ?before=<cursor> for the next
  -- page, ?limit=25 (1 to 100).
  get "/api/transactions" $ do
    user <- requireUser
    search <- maybe "" (T.take 100) <$> optionalParam "q"
    account <- fmap AccountId <$> optionalParam "account"
    before <- optionalParam "before"
    limit <- maybe (pure 25) (requireValid "invalid_limit" . parseBounded 1 100 "limit") =<< optionalParam "limit"
    (mine, names, entries) <- overviewData user
    -- Asking for an account that isn't one of yours: 404, as everywhere else.
    forM_ account $ \aid ->
      unless (aid `elem` map (accountId . fst) mine) $
        failWith status404 "unknown_account" "No such account." >> finish
    -- fromIntegral converts the Integer limit to the Int that splitAt wants.
    case transactionsPage (TransactionQuery account search before (fromIntegral limit)) names entries of
      Left msg -> failWith status400 "invalid_cursor" msg
      Right (items, nextCursor) ->
        json
          TransactionsPageView
            { transactionsPageViewItems =
                [ TransactionView
                    { transactionViewTransfer = let TransferId t = entryTransfer e in t
                    , transactionViewAccount = idText (entryAccount e)
                    , transactionViewAccountName = nameIn names (entryAccount e)
                    , transactionViewCounterparty = idText (entryCounterparty e)
                    , transactionViewCounterpartyName = nameIn names (entryCounterparty e)
                    , transactionViewAmountCents = centsOf (entryAmount e)
                    , transactionViewMemo = entryMemo e
                    , transactionViewCreatedAt = entryCreatedAt e
                    }
                | e <- items
                ]
            , transactionsPageViewNextCursor = nextCursor
            }

  -- Moving money ------------------------------------------------------------

  post "/api/deposits" $ do
    user <- requireUser
    unless (canDeposit user) $
      forbidden "Only admins can make deposits."
    DepositRequest {depositRequestTo = to, depositRequestAmountCents = cents} <- decodeBody
    -- Validate the raw number into an Amount right at the edge. After this
    -- line, "amount" is guaranteed valid (see Ledger.Money).
    amount <- requireAmount cents
    -- A deposit is just a transfer from the external account.
    runTransfer user (TransferRequest externalAccountId (AccountId to) amount "Deposit")

  post "/api/transfers" $ do
    user <- requireUser
    TransferRequestBody
      { transferRequestBodyFrom = from
      , transferRequestBodyTo = to
      , transferRequestBodyAmountCents = cents
      , transferRequestBodyMemo = rawMemo
      } <-
      decodeBody
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
  --
  -- Stored as "user:alice:payroll-1". The "user:" prefix keeps these apart
  -- from the seed's own keys ("seed:..."), and usernames can't contain ":",
  -- so no two users' keys can ever run together.
  let Username name = userName user
      scopedKey = IdempotencyKey . (("user:" <> name <> ":") <>) <$> key
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

-- | What the overview pages need: "my" accounts with balances (see
-- inOverview), a name for every account (to show "Globex Operating"
-- instead of globex-ops), and every entry on my accounts.
overviewData :: User -> Handler ([(Account, Cents)], Map.Map AccountId Text, [Entry])
overviewData user = do
  store <- lift (asks envStore)
  everything <- liftIO (storeListAccounts store)
  let mine = [(a, b) | (a, b) <- everything, inOverview user a]
      names = Map.fromList [(accountId a, accountName a) | (a, _) <- everything]
  entries <- liftIO (storeEntriesFor store (map (accountId . fst) mine))
  pure (mine, names, entries)

-- | A query-string parameter like ?month=2026-09, if it was sent.
-- params gives every parameter as (name, value) pairs of lazy Text.
optionalParam :: TL.Text -> Handler (Maybe Text)
optionalParam name = fmap TL.toStrict . lookup name <$> params

-- | "2026-09" -> the first day of that month.
parseMonth :: Text -> Either Text Day
parseMonth input = case T.splitOn "-" input of
  [y, m]
    | Just year <- readMaybe (T.unpack y)
    , Just mon <- readMaybe (T.unpack m)
    , Just day <- fromGregorianValid year mon 1 ->
        Right day
  _ -> Left "month must look like 2026-09."

-- | A whole number between lo and hi, e.g. ?days=90.
parseBounded :: Integer -> Integer -> Text -> Text -> Either Text Integer
parseBounded lo hi label input = case readMaybe (T.unpack input) of
  Just n | n >= lo && n <= hi -> Right n
  _ -> Left (label <> " must be a whole number from " <> T.pack (show lo) <> " to " <> T.pack (show hi) <> ".")

idText :: AccountId -> Text
idText (AccountId t) = t

centsOf :: Cents -> Integer
centsOf (Cents c) = c

-- | An account's display name, or its id if we somehow don't know it.
nameIn :: Map.Map AccountId Text -> AccountId -> Text
nameIn names aid = Map.findWithDefault (idText aid) aid names

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

-- | Should the session cookie be marked Secure for this request?
cookieShouldBeSecure :: Handler Bool
cookieShouldBeSecure = do
  policy <- lift (asks envCookiePolicy)
  httpRequest <- request
  let overHttps =
        isSecure httpRequest
          || lookup "X-Forwarded-Proto" (requestHeaders httpRequest) == Just "https"
  pure $ case policy of
    SecureAlways -> True
    SecureNever -> False
    SecureOverHttps -> overHttps

-- | The network address the request came from, e.g. "203.0.113.7", used to
-- count failed logins per address.
--
-- Behind a trusted reverse proxy (envTrustProxy), that's the LAST address
-- in X-Forwarded-For: the one our proxy saw. Earlier entries are whatever
-- the client claimed, so they're ignored. Without a trusted proxy the header
-- is ignored entirely, since anyone could send a fake one.
clientAddress :: Handler Text
clientAddress = do
  httpRequest <- request
  trustProxy <- lift (asks envTrustProxy)
  let forwarded = do
        headerValue <- lookup "X-Forwarded-For" (requestHeaders httpRequest)
        -- "a, b, c" -> the last non-empty entry, trimmed.
        case filter (not . T.null) (map T.strip (T.splitOn "," (decodeUtf8Lenient headerValue))) of
          [] -> Nothing
          entries -> Just (last entries)
  pure $ case (trustProxy, forwarded) of
    (True, Just address) -> address
    _ -> connectionAddress httpRequest
  where
    decodeUtf8Lenient = fromRight "" . decodeUtf8'

-- | The address of the machine connected to us.
connectionAddress :: Request -> Text
connectionAddress httpRequest =
  case remoteHost httpRequest of
    -- The port changes with every connection, so only the host counts.
    SockAddrInet _port host ->
      let (a, b, c, d) = hostAddressToTuple host
       in T.intercalate "." (map (T.pack . show) [a, b, c, d])
    SockAddrInet6 _port _flow host _scope -> T.pack (show (hostAddress6ToTuple host))
    other -> T.pack (show other)

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
  -- Only accept bodies that say they're JSON. A web page on another site
  -- can make a browser POST a plain form (text/plain, form-urlencoded) with
  -- your cookies attached, but it can't send application/json without the
  -- browser asking this server first (and this server never says yes).
  -- So this blocks cross-site request forgery even where SameSite=Lax
  -- doesn't (for example, from a sibling subdomain).
  contentType <- header "Content-Type"
  unless (maybe False (("application/json" `TL.isPrefixOf`) . TL.toLower) contentType) $
    failWith status415 "unsupported_media_type" "Send the request body as JSON, with Content-Type: application/json." >> finish
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
failWith st code msg = status st >> json (ErrorBody code msg)
