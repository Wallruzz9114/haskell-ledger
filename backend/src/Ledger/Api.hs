{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
-- This module gives TypeScript descriptions to types defined elsewhere
-- (Entry, AccountId, UTCTime...). An instance for a type and class that are
-- both defined in other modules is an "orphan", which GHC warns about. We
-- accept it on purpose: it keeps every TypeScript concern in this one file
-- instead of spreading it through the domain types.
{-# OPTIONS_GHC -Wno-orphans #-}

-- | The shape of everything the HTTP API sends and receives, in one place,
-- with TypeScript generated from the same definitions.
--
-- Before this module, the front end described the API's JSON by hand in
-- web/src/app/api.ts, and nothing checked the two stayed in step. Now:
--
--   * each request and response is a Haskell record here;
--   * its JSON encoder/decoder AND its TypeScript type are derived from the
--     same aeson Options, so they cannot disagree;
--   * the ledger-typescript program writes web/src/app/generated/apiTypes.ts
--     from apiDeclarations, and a test fails if that file is out of date.
--
-- So renaming a field in Haskell makes the front end fail to COMPILE,
-- instead of breaking quietly at runtime.
module Ledger.Api
  ( -- * Responses
    AccountView (..)
  , accountView
  , UserView (..)
  , userView
  , ErrorBody (..)

    -- * Requests
  , LoginRequest (..)
  , OpenAccountRequest (..)
  , SetOwnerRequest (..)
  , TransferRequestBody (..)
  , DepositRequest (..)

    -- * TypeScript
  , apiDeclarations
  , apiTypeScript
  ) where

import Data.Aeson (Options (..), defaultOptions)
import Data.Aeson.TypeScript.TH
import Data.Char (toLower)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Time (UTCTime)
import Ledger.JsonOptions (fieldsWithout, optionalFieldsWithout)
import Ledger.Money (Cents (..))
import Ledger.Types

-- Responses -----------------------------------------------------------------

-- | An account as the API shows it, with its balance.
--   { "id", "name", "kind", "owner" (null for system accounts), "balanceCents" }
data AccountView = AccountView
  { accountViewId :: Text
  , accountViewName :: Text
  , accountViewKind :: AccountKind
  , accountViewOwner :: Maybe Text
  , accountViewBalanceCents :: Integer
  }

-- | Who is logged in: { "username", "role" }.
data UserView = UserView
  { userViewUsername :: Text
  , userViewRole :: Role
  }

-- | Every error response: { "error": "insufficient_funds", "message": "..." }.
data ErrorBody = ErrorBody
  { errorBodyError :: Text
  , errorBodyMessage :: Text
  }

accountView :: Account -> Cents -> AccountView
accountView a (Cents bal) =
  AccountView
    { accountViewId = let AccountId t = accountId a in t
    , accountViewName = accountName a
    , accountViewKind = accountKind a
    , accountViewOwner = (\(Username u) -> u) <$> accountOwner a
    , accountViewBalanceCents = bal
    }

userView :: User -> UserView
userView u = UserView {userViewUsername = let Username t = userName u in t, userViewRole = userRole u}

-- Requests ------------------------------------------------------------------

-- | { "username", "password" }
data LoginRequest = LoginRequest
  { loginRequestUsername :: Text
  , loginRequestPassword :: Text
  }

-- | { "id", "name", "owner"? }. The owner defaults to whoever is logged in.
data OpenAccountRequest = OpenAccountRequest
  { openAccountRequestId :: Text
  , openAccountRequestName :: Text
  , openAccountRequestOwner :: Maybe Text
  }

-- | { "owner" }
newtype SetOwnerRequest = SetOwnerRequest
  { setOwnerRequestOwner :: Text
  }

-- | { "from", "to", "amountCents", "memo"? }
data TransferRequestBody = TransferRequestBody
  { transferRequestBodyFrom :: Text
  , transferRequestBodyTo :: Text
  , transferRequestBodyAmountCents :: Integer
  , transferRequestBodyMemo :: Maybe Text
  }

-- | { "to", "amountCents" }
data DepositRequest = DepositRequest
  { depositRequestTo :: Text
  , depositRequestAmountCents :: Integer
  }

-- Deriving JSON and TypeScript together --------------------------------------

-- "$(...)" runs Template Haskell at compile time (see Ledger.Db). Each
-- splice below writes instances for one type.
--
-- ORDER MATTERS: every splice splits the module into sections, and a splice
-- can only see instances defined ABOVE it. So the small building blocks
-- come first, then the records that contain them.

-- Newtypes that travel as plain JSON strings or numbers.
instance TypeScript AccountId where getTypeScriptType _ = "string"
instance TypeScript TransferId where getTypeScriptType _ = "number"
instance TypeScript Cents where getTypeScriptType _ = "number"
-- aeson writes times as ISO 8601 strings, e.g. "2026-09-29T18:05:12Z".
instance TypeScript UTCTime where getTypeScriptType _ = "string"

-- Types whose JSON is already defined in Ledger.Types: only their TypeScript
-- is derived here, from the very same Options their ToJSON uses.
$(deriveTypeScript defaultOptions ''AccountKind)
$(deriveTypeScript (stripPrefix 5) ''Entry)
$(deriveTypeScript (stripPrefix 8) ''Transfer)

-- Role's JSON is "customer" or "admin": the constructor name without "Role",
-- lowercased.
$(deriveJSONAndTypeScript defaultOptions {constructorTagModifier = map toLower . drop 4} ''Role)

-- The API's own records. Each line writes ToJSON, FromJSON and TypeScript
-- instances from the same Options, so the JSON and the TypeScript can't
-- drift apart. Responses use fieldsWithout (a missing value is null);
-- requests use optionalFieldsWithout (optional fields may be left out).
-- Both come from Ledger.JsonOptions: code that runs at compile time can
-- only use functions imported from another module.
$(deriveJSONAndTypeScript (fieldsWithout "accountView") ''AccountView)
$(deriveJSONAndTypeScript (fieldsWithout "userView") ''UserView)
$(deriveJSONAndTypeScript (fieldsWithout "errorBody") ''ErrorBody)
$(deriveJSONAndTypeScript (optionalFieldsWithout "loginRequest") ''LoginRequest)
$(deriveJSONAndTypeScript (optionalFieldsWithout "openAccountRequest") ''OpenAccountRequest)
$(deriveJSONAndTypeScript (optionalFieldsWithout "setOwnerRequest") ''SetOwnerRequest)
$(deriveJSONAndTypeScript (optionalFieldsWithout "transferRequestBody") ''TransferRequestBody)
$(deriveJSONAndTypeScript (optionalFieldsWithout "depositRequest") ''DepositRequest)

-- Output ----------------------------------------------------------------------

-- | Every type the front end uses, as TypeScript declarations.
apiDeclarations :: [TSDeclaration]
apiDeclarations =
  concat
    [ getTypeScriptDeclarations (Proxy :: Proxy AccountView)
    , getTypeScriptDeclarations (Proxy :: Proxy AccountKind)
    , getTypeScriptDeclarations (Proxy :: Proxy UserView)
    , getTypeScriptDeclarations (Proxy :: Proxy Role)
    , getTypeScriptDeclarations (Proxy :: Proxy Entry)
    , getTypeScriptDeclarations (Proxy :: Proxy Transfer)
    , getTypeScriptDeclarations (Proxy :: Proxy ErrorBody)
    , getTypeScriptDeclarations (Proxy :: Proxy LoginRequest)
    , getTypeScriptDeclarations (Proxy :: Proxy OpenAccountRequest)
    , getTypeScriptDeclarations (Proxy :: Proxy SetOwnerRequest)
    , getTypeScriptDeclarations (Proxy :: Proxy TransferRequestBody)
    , getTypeScriptDeclarations (Proxy :: Proxy DepositRequest)
    ]

-- | The whole generated file: a header, then every declaration, exported.
apiTypeScript :: String
apiTypeScript =
  unlines
    [ "// Generated from the Haskell types in backend/src/Ledger/Api.hs."
    , "// Do not edit by hand: run `cabal run -v0 ledger-typescript > web/src/app/generated/apiTypes.ts`"
    , "// from the repository root. A backend test fails if this file is out of date."
    , ""
    ]
    <> formatTSDeclarations' defaultFormattingOptions {exportMode = ExportEach} apiDeclarations
