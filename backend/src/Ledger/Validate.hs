{-# LANGUAGE OverloadedStrings #-}

-- | Rules for the free-text values clients send: account ids and names,
-- memos, and idempotency keys. Ledger.App checks each one at the edge and
-- answers 400 if it's broken, so bad text never reaches the store.
--
-- Each check returns "Either Text Text": Left with an error message, or
-- Right with the cleaned-up value (surrounding spaces trimmed).
module Ledger.Validate
  ( validAccountId
  , validAccountName
  , validMemo
  , validIdempotencyKey
  ) where

import Data.Char (isAsciiLower, isDigit)
import Data.Text (Text)
import qualified Data.Text as T

-- | 1 to 64 characters: lowercase letters, digits and "-", like "acme-ops".
--
-- Ids appear in URLs (/api/accounts/acme-ops), so characters like "/" or
-- spaces would create accounts that can never be fetched again.
validAccountId :: Text -> Either Text Text
validAccountId raw
  | T.null aid = Left "Account id is required."
  | T.length aid > 64 = Left "Account id must be at most 64 characters."
  -- T.all p t: True if every character satisfies p.
  | not (T.all allowed aid) = Left "Account id may only use lowercase letters, digits and \"-\"."
  | otherwise = Right aid
  where
    aid = T.strip raw
    allowed c = isAsciiLower c || isDigit c || c == '-'

-- | 1 to 100 characters, after trimming surrounding spaces.
validAccountName :: Text -> Either Text Text
validAccountName raw
  | T.null name = Left "Account name is required."
  | T.length name > 100 = Left "Account name must be at most 100 characters."
  | otherwise = Right name
  where
    name = T.strip raw

-- | Optional, at most 500 characters.
validMemo :: Text -> Either Text Text
validMemo raw
  | T.length memo > 500 = Left "Memo must be at most 500 characters."
  | otherwise = Right memo
  where
    memo = T.strip raw

-- | 1 to 255 characters, with no spaces or control characters. Clients
-- usually send a UUID.
validIdempotencyKey :: Text -> Either Text Text
validIdempotencyKey key
  | T.null key = Left "Idempotency-Key must not be empty."
  | T.length key > 255 = Left "Idempotency-Key must be at most 255 characters."
  -- '!' to '~' is every visible ASCII character: no spaces, tabs or newlines.
  | not (T.all (\c -> c >= '!' && c <= '~') key) = Left "Idempotency-Key may only use visible ASCII characters."
  | otherwise = Right key
