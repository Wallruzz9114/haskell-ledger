-- | JSON naming options shared by Ledger.Api's derived instances.
--
-- This lives in its own module because of Template Haskell's "stage
-- restriction": code that runs at compile time (the $(...) splices in
-- Ledger.Api) can only call functions IMPORTED from another module, which
-- GHC has already compiled, not ones defined in the same file.
module Ledger.JsonOptions
  ( fieldsWithout
  , optionalFieldsWithout
  ) where

import Data.Aeson (Options (..), defaultOptions)
import Data.Char (toLower)

-- | For responses. Field names without the record prefix, first letter
-- lowercased: fieldsWithout "accountView" turns accountViewBalanceCents
-- into "balanceCents". A Maybe field that's Nothing is sent as null, so
-- the field is always there (TypeScript: "owner: string | null").
fieldsWithout :: String -> Options
fieldsWithout prefix = defaultOptions {fieldLabelModifier = lowerFirst . drop (length prefix)}
  where
    lowerFirst (c : cs) = toLower c : cs
    lowerFirst [] = []

-- | For requests. The same names, but a Maybe field may be left out
-- entirely (TypeScript: "memo?: string"), so clients only send what they
-- need.
optionalFieldsWithout :: String -> Options
optionalFieldsWithout prefix = (fieldsWithout prefix) {omitNothingFields = True}
