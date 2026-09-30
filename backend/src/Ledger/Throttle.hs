{-# LANGUAGE OverloadedStrings #-}

-- | Protecting the login endpoint.
--
-- Checking a password is deliberately expensive (Argon2: ~50 ms and 64 MB),
-- and crypton runs it as an "unsafe" foreign call, which holds a CPU core
-- until it finishes. Without limits, anyone could send a flood of login
-- attempts and keep every core busy hashing. Two defences:
--
--   * Failed-attempt limits: too many wrong passwords for one username, or
--     from one address, and further attempts are refused for a while WITHOUT
--     hashing anything. This also stops password guessing.
--
--   * Hash slots: at most a few password checks run at the same time. When
--     they're all busy, a login is refused straight away ("try again"),
--     instead of queueing up and eating memory.
--
-- The counting logic is pure (Failures, recordFailure, blockedUntil) so it's
-- easy to test; LoginGuard wraps it in STM for use by the web server.
--
-- The counts live in the server's memory, so each server process counts on
-- its own and a restart clears them. Several servers behind a load balancer
-- would need a shared store (Postgres or Redis) instead.
module Ledger.Throttle
  ( -- * Pure counting
    Limit (..)
  , Failures
  , noFailures
  , recordFailure
  , clearFailures
  , blockedUntil

    -- * The guard the web server uses
  , LoginGuard
  , newLoginGuard
  , loginBlockedUntil
  , loginFailed
  , loginSucceeded
  , withHashSlot
  ) where

import Control.Concurrent.STM
import Control.Exception (finally, mask)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import Data.Ord (Down (..))
import Data.Text (Text)
import Data.Time (NominalDiffTime, UTCTime, addUTCTime)

-- | "At most limitCount failures within limitWindow."
data Limit = Limit
  { limitCount :: Int
  , limitWindow :: NominalDiffTime
  }

-- | Recent failure times for each key. A key is a name for what's being
-- counted, e.g. "user:alice" or "ip:203.0.113.7".
newtype Failures = Failures (Map Text [UTCTime])

noFailures :: Failures
noFailures = Failures Map.empty

-- | Remember one more failure for this key at this time. Failures older
-- than the window are dropped, for every key, so the map can't grow without
-- bound.
recordFailure :: Limit -> UTCTime -> Text -> Failures -> Failures
recordFailure limit now key (Failures m) =
  Failures (Map.filter (not . null) (Map.map recent (Map.insertWith (++) key [now] m)))
  where
    recent = filter (\t -> t > addUTCTime (negate (limitWindow limit)) now)

-- | Forget a key's failures, e.g. after a successful login.
clearFailures :: Text -> Failures -> Failures
clearFailures key (Failures m) = Failures (Map.delete key m)

-- | If this key has reached the limit, the time when it may try again.
--
-- It may try again once enough old failures fall out of the window: when
-- the oldest of the last limitCount failures is limitWindow old.
blockedUntil :: Limit -> UTCTime -> Text -> Failures -> Maybe UTCTime
blockedUntil limit now key (Failures m) =
  -- Newest first: sortOn Down sorts from largest (latest) to smallest.
  case take (limitCount limit) (sortOn Down recent) of
    newest | length newest >= limitCount limit, not (null newest) ->
      Just (addUTCTime (limitWindow limit) (last newest))
    _ -> Nothing
  where
    recent = filter (\t -> t > addUTCTime (negate (limitWindow limit)) now) (Map.findWithDefault [] key m)

-- The guard ---------------------------------------------------------------------

-- | Shared, thread-safe login state for the whole server.
data LoginGuard = LoginGuard
  { guardUserLimit :: Limit
  , guardAddressLimit :: Limit
  , guardFailures :: TVar Failures
  , guardFreeSlots :: TVar Int
  }

-- | A guard allowing, per 15 minutes, 5 wrong passwords for one username
-- and 30 from one network address, with this many password checks at once.
newLoginGuard :: Int -> IO LoginGuard
newLoginGuard slots =
  LoginGuard (Limit 5 (15 * 60)) (Limit 30 (15 * 60))
    <$> newTVarIO noFailures
    <*> newTVarIO slots

-- | If this username or this address is blocked, when it may try again
-- (the later of the two).
loginBlockedUntil :: LoginGuard -> UTCTime -> Text -> Text -> IO (Maybe UTCTime)
loginBlockedUntil guard now user address = do
  failures <- readTVarIO (guardFailures guard)
  let blocks =
        mapMaybe
          (\(limit, key) -> blockedUntil limit now key failures)
          [(guardUserLimit guard, userKey user), (guardAddressLimit guard, addressKey address)]
  pure (if null blocks then Nothing else Just (maximum blocks))

-- | Count a failed login against both the username and the address.
loginFailed :: LoginGuard -> UTCTime -> Text -> Text -> IO ()
loginFailed guard now user address =
  atomically . modifyTVar' (guardFailures guard) $
    recordFailure (guardUserLimit guard) now (userKey user)
      . recordFailure (guardAddressLimit guard) now (addressKey address)

-- | A successful login clears that username's failures (not the address's:
-- one right password shouldn't reset a count built up guessing others).
loginSucceeded :: LoginGuard -> Text -> IO ()
loginSucceeded guard user = atomically (modifyTVar' (guardFailures guard) (clearFailures (userKey user)))

-- | Run a password check in one of the limited slots, or give back Nothing
-- straight away if they're all busy.
--
-- "mask" and "finally" make sure a slot taken is always given back, even if
-- the check throws or the request is cancelled halfway.
withHashSlot :: LoginGuard -> IO a -> IO (Maybe a)
withHashSlot guard action = mask $ \restore -> do
  gotSlot <- atomically $ do
    free <- readTVar (guardFreeSlots guard)
    if free > 0
      then writeTVar (guardFreeSlots guard) (free - 1) >> pure True
      else pure False
  if gotSlot
    then (Just <$> restore action) `finally` atomically (modifyTVar' (guardFreeSlots guard) (+ 1))
    else pure Nothing

userKey, addressKey :: Text -> Text
userKey = ("user:" <>)
addressKey = ("ip:" <>)
