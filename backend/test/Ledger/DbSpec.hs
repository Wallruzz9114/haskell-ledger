-- | Tests for the startup retry helper in Ledger.Db.
module Ledger.DbSpec (spec) where

import Control.Exception (ArithException (..), throwIO)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Ledger.Db (retrying)
import Test.Hspec

spec :: Spec
spec = do
  -- These tests wait between attempts (0.5 s, then 1 s), so they take a
  -- couple of seconds.
  it "keeps trying until the action succeeds" $ do
    calls <- newIORef (0 :: Int)
    let flaky = do
          modifyIORef' calls (+ 1)
          n <- readIORef calls
          if n < 3 then throwIO Overflow else pure "connected"
    retrying 5 quietly flaky `shouldReturn` "connected"
    readIORef calls `shouldReturn` 3

  it "gives up after the last attempt" $ do
    calls <- newIORef (0 :: Int)
    let broken = modifyIORef' calls (+ 1) >> throwIO Overflow :: IO ()
    retrying 2 quietly broken `shouldThrow` anyIOException
    readIORef calls `shouldReturn` 2

  it "doesn't retry a different kind of error" $ do
    calls <- newIORef (0 :: Int)
    -- retrying is told to retry ArithException; this throws something else.
    let wrongKind = modifyIORef' calls (+ 1) >> ioError (userError "a bug") :: IO ()
    retrying 5 quietly wrongKind `shouldThrow` anyIOException
    readIORef calls `shouldReturn` 1
  where
    quietly :: Int -> ArithException -> IO ()
    quietly _ _ = pure ()
