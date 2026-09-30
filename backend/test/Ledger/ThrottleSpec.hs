{-# LANGUAGE OverloadedStrings #-}

-- | Tests for Ledger.Throttle: failed-login limits and password-check slots.
module Ledger.ThrottleSpec (spec) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import qualified Data.Text as T
import Data.Time (UTCTime (..), addUTCTime, fromGregorian)
import Ledger.Throttle
import Test.Hspec

-- | A fixed moment, so the tests don't depend on the clock.
start :: UTCTime
start = UTCTime (fromGregorian 2026 9 29) 0

-- | 3 failures per 60 seconds.
limit :: Limit
limit = Limit 3 60

-- | n failures for "k", one second apart, starting at "start".
failures :: Int -> Failures
failures n = foldl (\f i -> recordFailure limit (addUTCTime (fromIntegral i) start) "k" f) noFailures [0 .. n - 1]

spec :: Spec
spec = do
  describe "counting failures" $ do
    it "doesn't block below the limit" $
      blockedUntil limit (addUTCTime 5 start) "k" (failures 2) `shouldBe` Nothing

    it "blocks at the limit, until the oldest counted failure is a window old" $
      -- Failures at 0, 1 and 2 seconds: the first leaves the window at 60.
      blockedUntil limit (addUTCTime 5 start) "k" (failures 3) `shouldBe` Just (addUTCTime 60 start)

    it "stops blocking once the window has passed" $
      blockedUntil limit (addUTCTime 61 start) "k" (failures 3) `shouldBe` Nothing

    it "counts each key separately" $
      blockedUntil limit (addUTCTime 5 start) "other" (failures 3) `shouldBe` Nothing

    it "forgets a key's failures when cleared" $
      blockedUntil limit (addUTCTime 5 start) "k" (clearFailures "k" (failures 3)) `shouldBe` Nothing

  describe "the login guard" $ do
    it "blocks a username after 5 failures, but not other usernames" $ do
      guard <- newLoginGuard 2
      failFiveTimes guard "alice"
      loginBlockedUntil guard (addUTCTime 5 start) "alice" "10.0.0.2" >>= (`shouldSatisfy` (/= Nothing))
      loginBlockedUntil guard (addUTCTime 5 start) "bob" "10.0.0.2" `shouldReturn` Nothing

    it "blocks an address after 30 failures, whatever the username" $ do
      guard <- newLoginGuard 2
      mapM_ (\i -> loginFailed guard (addUTCTime (fromIntegral i) start) ("user" <> T.pack (show i)) "10.0.0.9") [0 .. 29 :: Int]
      loginBlockedUntil guard (addUTCTime 30 start) "someone-new" "10.0.0.9" >>= (`shouldSatisfy` (/= Nothing))

    it "clears a username's failures after a successful login" $ do
      guard <- newLoginGuard 2
      failFiveTimes guard "alice"
      loginSucceeded guard "alice"
      loginBlockedUntil guard (addUTCTime 5 start) "alice" "10.0.0.3" `shouldReturn` Nothing

  describe "password-check slots" $ do
    it "runs the action when a slot is free" $ do
      guard <- newLoginGuard 1
      withHashSlot guard (pure "done") `shouldReturn` Just ("done" :: String)

    it "refuses straight away when every slot is busy, and frees the slot afterwards" $ do
      guard <- newLoginGuard 1
      started <- newEmptyMVar
      release <- newEmptyMVar
      finished <- newEmptyMVar
      -- Hold the only slot in another thread until we say so.
      _ <- forkIO $ do
        _ <- withHashSlot guard (putMVar started () >> takeMVar release)
        putMVar finished ()
      takeMVar started
      withHashSlot guard (pure ()) `shouldReturn` Nothing
      putMVar release ()
      takeMVar finished
      withHashSlot guard (pure ()) `shouldReturn` Just ()

-- | Five failed logins for this username, one second apart.
--
-- The seconds are counted as Ints and converted with fromIntegral. Writing
-- [0 .. 4] directly as time lengths (NominalDiffTime) would be a trap:
-- that type counts in picoseconds, so the list would have 4 trillion items.
failFiveTimes :: LoginGuard -> T.Text -> IO ()
failFiveTimes guard user =
  mapM_ (\i -> loginFailed guard (addUTCTime (fromIntegral i) start) user "10.0.0.1") [0 .. 4 :: Int]
