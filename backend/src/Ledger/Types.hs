-- DeriveGeneric lets us write "deriving (Generic)", which makes the compiler
-- produce a machine-readable description of a type's shape (its constructors
-- and field names). Libraries like aeson read that description to build JSON
-- encoders for us, so we don't write them by hand.
{-# LANGUAGE DeriveGeneric #-}

-- | Domain types. Errors are modelled as what went wrong in the business,
-- not as HTTP status codes; the HTTP layer translates them at the edge.
--
-- This file only DESCRIBES data. There is no logic here: the rules for moving
-- money live in Ledger.Core, and HTTP lives in Ledger.App.
module Ledger.Types
  -- "Name (..)" exports a type together with its constructors and fields,
  -- so other modules can build and take apart these values freely.
  ( AccountId (..)
  , AccountKind (..)
  , Account (..)
  , TransferId (..)
  , IdempotencyKey (..)
  , Entry (..)
  , Transfer (..)
  , TransferRequest (..)
  , TransferError (..)
  , OpenAccountError (..)
  ) where

-- "ToJSON (..)" imports the class AND its methods (we need its toJSON method
-- below). "Options (..)" imports the type and its fields (fieldLabelModifier).
import Data.Aeson (FromJSON, Options (..), ToJSON (..), defaultOptions, genericToJSON)
import Data.Char (toLower)
-- Text is the string type real Haskell code uses. The built-in String is a
-- linked list of characters, which is slow; Text is a packed, efficient string.
import Data.Text (Text)
import GHC.Generics (Generic)
-- Our own module from Money.hs. Note we get Amount but not its constructor:
-- Money.hs didn't export it, so the only way to make one is mkAmount.
import Ledger.Money (Amount, Cents)

-- | An account's identifier, e.g. "acme-ops".
--
-- It's a Text underneath, but wrapped in its own type so an AccountId can't
-- be passed where some other Text (a memo, an idempotency key) is expected.
-- TypeScript would treat both as plain "string" and allow the mix-up.
newtype AccountId = AccountId Text
  -- Ord ("can be compared/sorted") is required because AccountId is used as
  -- a key in a Map in Ledger.Core, and Maps are sorted trees.
  deriving (Eq, Ord, Show, Generic)

-- An "instance" says "this type implements this class (interface)".
-- No "where" block means "use the default implementation", which aeson
-- builds from the Generic description. Result: AccountId "acme" <-> "acme".
instance ToJSON AccountId

instance FromJSON AccountId

-- | Customer accounts may never go below zero. The external account
-- represents money outside the ledger (deposits come from it, withdrawals
-- go to it), so it is allowed to be negative.
--
-- "|" means OR: an AccountKind is exactly one of these two values, nothing
-- else. Like TypeScript's: type AccountKind = 'Customer' | 'External'.
-- When code uses "case" on it, the compiler warns if a case is missing.
data AccountKind = Customer | External
  deriving (Eq, Show, Generic)

-- Only ToJSON, no FromJSON: the API sends account kinds out but never reads
-- them in, so we don't create a parser we don't need.
instance ToJSON AccountKind

-- | A record: a type with named fields, like a TypeScript interface.
--
-- The first "Account" is the type's name; the second is the constructor
-- function that builds one: Account (AccountId "a") "Name" Customer.
--
-- Each field also becomes a function you can call, e.g.
--   accountName :: Account -> Text
-- so you write "accountName acct", not "acct.accountName".
--
-- The "account" prefix on every field is because field names become
-- top-level functions, so two records in one module can't both have "id".
data Account = Account
  { accountId :: AccountId
  , accountName :: Text
  , accountKind :: AccountKind
  }
  deriving (Eq, Show, Generic)

instance ToJSON Account

-- | Transfers are numbered 1, 2, 3... in the order they happen.
newtype TransferId = TransferId Integer
  deriving (Eq, Ord, Show, Generic)

instance ToJSON TransferId

-- | A client-chosen key sent in the Idempotency-Key HTTP header. If the same
-- request arrives twice with the same key (a double-click, a network retry),
-- the money moves only once.
--
-- No Generic or JSON instances: it only ever arrives as a header, never in
-- a JSON body, so it doesn't need them.
newtype IdempotencyKey = IdempotencyKey Text
  deriving (Eq, Ord, Show)

-- | Double-entry bookkeeping: every transfer writes two entries whose
-- amounts sum to zero. A balance is just the sum of an account's entries.
--
-- Example: moving 500 cents from alice to bob writes
--   Entry (TransferId 1) (AccountId "alice") (Cents (-500))
--   Entry (TransferId 1) (AccountId "bob")   (Cents 500)
data Entry = Entry
  { entryTransfer :: TransferId
  , entryAccount :: AccountId
  , entryAmount :: Cents
  }
  deriving (Eq, Show, Generic)

-- Here we DO write the instance body, to customise the JSON field names.
-- genericToJSON still builds the encoder from Generic, but with options:
-- stripPrefix 5 drops "entry" (5 letters), so the JSON is
--   {"transfer": 1, "account": "alice", "amount": -500}
-- instead of {"entryTransfer": 1, ...}.
instance ToJSON Entry where
  toJSON = genericToJSON (stripPrefix 5)

-- | A transfer that has happened: the request plus the ID it was given.
--
-- Note transferAmount is Cents, not Amount: by this point the amount was
-- already validated, and Cents is what we store and send as JSON.
data Transfer = Transfer
  { transferId :: TransferId
  , transferFrom :: AccountId
  , transferTo :: AccountId
  , transferAmount :: Cents
  , transferMemo :: Text
  }
  deriving (Eq, Show, Generic)

-- stripPrefix 8 drops "transfer" (8 letters): transferId -> id,
-- transferAmount -> amount, and so on.
instance ToJSON Transfer where
  toJSON = genericToJSON (stripPrefix 8)

-- | What someone ASKS for: "move this much from A to B".
--
-- reqAmount is an Amount, not Cents. Since the only way to get an Amount is
-- mkAmount (which rejects zero and negatives), every TransferRequest that
-- exists is guaranteed to have a positive amount. The type system does the
-- validation, so Ledger.Core never needs to check it again.
data TransferRequest = TransferRequest
  { reqFrom :: AccountId
  , reqTo :: AccountId
  , reqAmount :: Amount
  , reqMemo :: Text
  }
  deriving (Eq, Show)

-- | Every way a transfer can fail, as plain data instead of exceptions.
--
-- Each alternative ("constructor") can carry different data:
--   UnknownAccount carries the id that wasn't found
--   SameAccount carries nothing
--   InsufficientFunds carries two named fields
-- In TypeScript this would be a discriminated union:
--   | { kind: 'UnknownAccount', id: AccountId }
--   | { kind: 'SameAccount' }
--   | { kind: 'InsufficientFunds', available: Cents, requested: Cents }
--   | { kind: 'IdempotencyKeyReused' }
--
-- Functions return "Either TransferError Transfer": either an error (Left)
-- or a result (Right). The caller must handle both to get at the value.
data TransferError
  = UnknownAccount AccountId
  | SameAccount
  | InsufficientFunds {available :: Cents, requested :: Cents}
  | IdempotencyKeyReused
  deriving (Eq, Show)

-- | Opening an account can only fail one way, so this has one constructor.
-- A type with exactly one constructor holding one value can be a newtype.
newtype OpenAccountError = AccountAlreadyExists AccountId
  deriving (Eq, Show)

-- | JSON field names without the Haskell record prefix:
-- @transferAmount@ becomes @amount@, @entryAccount@ becomes @account@.
--
-- "Int -> Options" means: takes an Int, returns aeson Options.
stripPrefix :: Int -> Options
-- "defaultOptions {fieldLabelModifier = ...}" is record update syntax: a copy
-- of defaultOptions with one field changed. In TypeScript:
--   { ...defaultOptions, fieldLabelModifier: ... }
--
-- "lowerFirst . drop n" is function composition. Read it right to left:
-- first drop n characters, then lowercase the first remaining one.
-- "transferAmount" -> drop 8 -> "Amount" -> lowerFirst -> "amount"
stripPrefix n = defaultOptions {fieldLabelModifier = lowerFirst . drop n}
  -- "where" defines helpers visible only inside stripPrefix.
  where
    -- Two equations, chosen by pattern matching on the string (a String is
    -- a list of characters):
    --   (c : cs) matches a non-empty list: first character c, the rest cs.
    --            ":" puts a character back on the front of a list.
    --   []       matches the empty list.
    -- -Wall warns if you leave out a case, e.g. forget the [] line.
    lowerFirst (c : cs) = toLower c : cs
    lowerFirst [] = []
