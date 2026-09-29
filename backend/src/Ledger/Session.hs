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
module Ledger.Session
  ( TokenHash (..)
  , hashPassword
  , passwordMatches
  , newSessionToken
  , hashToken
  , sessionLifetime
  ) where

import Crypto.Hash (SHA256 (..), hashWith)
import Crypto.Random (getRandomBytes)
import Data.ByteArray (convert)
import Data.ByteArray.Encoding (Base (..), convertToBase)
import Data.ByteString (ByteString)
import Data.Password.Argon2 (PasswordCheck (..), PasswordHash (..), mkPassword)
import qualified Data.Password.Argon2 as Argon2
import Data.Text (Text)
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Data.Time (NominalDiffTime)

-- | The SHA-256 hash of a session token: what the stores keep and look up.
newtype TokenHash = TokenHash ByteString
  deriving (Eq, Ord, Show)

-- | Hash a password for storage. The result includes a random salt and the
-- Argon2 settings, so the same password hashes differently every time.
hashPassword :: Text -> IO Text
hashPassword plain = unPasswordHash <$> Argon2.hashPassword (mkPassword plain)

-- | Does this password match the stored hash?
passwordMatches :: Text -> Text -> Bool
passwordMatches plain stored =
  Argon2.checkPassword (mkPassword plain) (PasswordHash stored) == PasswordCheckSuccess

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
