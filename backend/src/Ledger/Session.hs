-- | Passwords and session tokens: the security-sensitive parts of logging in.
--
-- Two rules this module exists to enforce:
--
--   * Passwords are never stored, only Argon2 hashes of them. Argon2 is
--     deliberately slow and memory-hungry, so someone who steals the users
--     table can't try billions of guesses per second.
--
--   * Session tokens are never stored either. The browser keeps a random
--     token in a cookie; the database keeps its SHA-256 hash. A stolen copy
--     of the sessions table can't be turned back into working cookies.
{-# LANGUAGE OverloadedStrings #-}

-- (OverloadedStrings: literals like "$argon2id" below are Text.)
module Ledger.Session
  ( TokenHash (..)
  , hashPassword
  , passwordMatches
  , newSessionToken
  , hashToken
  , sessionLifetime
  ) where

import Crypto.Error (CryptoFailable (..))
import Crypto.Hash (SHA256 (..), hashWith)
import qualified Crypto.KDF.Argon2 as Argon2
import Crypto.Random (getRandomBytes)
import Data.ByteArray (constEq, convert)
import Data.ByteArray.Encoding (Base (..), convertFromBase, convertToBase)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Data.Time (NominalDiffTime)
import Text.Read (readMaybe)

-- | The SHA-256 hash of a session token: what the stores keep and look up.
newtype TokenHash = TokenHash ByteString
  deriving (Eq, Ord, Show)

-- | Argon2id settings: 64 MB of memory and 2 passes over it, per hash.
-- That makes each guess cost an attacker real memory and time.
argon2Options :: Argon2.Options
argon2Options =
  Argon2.Options
    { Argon2.iterations = 2
    , Argon2.memory = 65536 -- in KiB: 64 MB
    , Argon2.parallelism = 1
    , Argon2.variant = Argon2.Argon2id
    , Argon2.version = Argon2.Version13
    }

-- | Hash a password for storage. A fresh random salt means the same
-- password hashes differently every time, so identical passwords can't be
-- spotted in the table.
--
-- The result is in the standard "PHC" text format that other Argon2 tools
-- read and write, with the settings and salt stored alongside the hash:
--   $argon2id$v=19$m=65536,t=2,p=1$<salt>$<hash>
hashPassword :: Text -> IO Text
hashPassword plain = do
  salt <- getRandomBytes 16 :: IO ByteString
  case argon2 argon2Options plain salt 32 of
    Just digest -> pure (encodePhc argon2Options salt digest)
    Nothing -> fail "Argon2 rejected its own settings"

-- | Does this password match the stored hash? Re-hashes the password with
-- the salt and settings stored in the hash, then compares.
passwordMatches :: Text -> Text -> Bool
passwordMatches plain stored = case decodePhc stored of
  Just (options, salt, expected) -> case argon2 options plain salt (BS.length expected) of
    -- constEq takes the same time whether the bytes differ at the first
    -- position or the last, so timing can't leak how close a guess was.
    Just actual -> constEq actual expected
    Nothing -> False
  Nothing -> False

-- | Run Argon2. crypton reports failure (for example, impossible settings)
-- as CryptoFailed instead of throwing; we turn that into Nothing.
argon2 :: Argon2.Options -> Text -> ByteString -> Int -> Maybe ByteString
argon2 options plain salt len = case Argon2.hash options (encodeUtf8 plain) salt len of
  CryptoPassed digest -> Just digest
  CryptoFailed _ -> Nothing

encodePhc :: Argon2.Options -> ByteString -> ByteString -> Text
encodePhc options salt digest =
  T.intercalate
    "$"
    [ ""
    , "argon2id"
    , "v=19"
    , "m=" <> showT (Argon2.memory options) <> ",t=" <> showT (Argon2.iterations options) <> ",p=" <> showT (Argon2.parallelism options)
    , base64 salt
    , base64 digest
    ]
  where
    showT :: Show a => a -> Text
    showT = T.pack . show
    -- Standard base64 without the trailing "=" padding, as PHC requires.
    base64 = T.dropWhileEnd (== '=') . decodeUtf8 . convertToBase Base64

-- | Read "$argon2id$v=19$m=...,t=...,p=...$<salt>$<hash>" back into its
-- settings, salt and hash. Nothing if it isn't in that shape.
decodePhc :: Text -> Maybe (Argon2.Options, ByteString, ByteString)
decodePhc stored = case T.splitOn "$" stored of
  ["", "argon2id", "v=19", params, salt64, hash64] -> do
    -- A do block in Maybe: any Nothing (a missing or unreadable part)
    -- makes the whole result Nothing.
    [m, t, p] <- traverse number (zip ["m=", "t=", "p="] (T.splitOn "," params))
    salt <- unbase64 salt64
    digest <- unbase64 hash64
    pure (argon2Options {Argon2.memory = m, Argon2.iterations = t, Argon2.parallelism = p}, salt, digest)
  _ -> Nothing
  where
    -- ("m=", "m=65536") -> Just 65536
    number (prefix, part) = T.stripPrefix prefix part >>= readMaybe . T.unpack
    -- Put back the "=" padding that PHC leaves off, then decode.
    unbase64 t =
      let padded = t <> T.replicate ((4 - T.length t `mod` 4) `mod` 4) "="
       in either (const Nothing) Just (convertFromBase Base64 (encodeUtf8 padded))

-- | A new random session token, and its hash.
--
-- 32 random bytes from a cryptographically secure source (256 bits: far too
-- many to guess), written as URL-safe base64 so it fits in a cookie.
newSessionToken :: IO (Text, TokenHash)
newSessionToken = do
  bytes <- getRandomBytes 32 :: IO ByteString
  let token = decodeUtf8 (convertToBase Base64URLUnpadded bytes)
  pure (token, hashToken token)

-- | Hash a token the same way newSessionToken did, to look it up.
hashToken :: Text -> TokenHash
hashToken token = TokenHash (convert (hashWith SHA256 (encodeUtf8 token)))

-- | How long a login lasts: 7 days. NominalDiffTime counts seconds.
sessionLifetime :: NominalDiffTime
sessionLifetime = 7 * 24 * 60 * 60
