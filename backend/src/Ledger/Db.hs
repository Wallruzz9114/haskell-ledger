-- TemplateHaskell runs Haskell code AT COMPILE TIME. We use it once, to read
-- the SQL files in db/migrations and bake their contents into the program,
-- so the binary carries its own schema and never has to find the files at
-- runtime.
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

-- | Database plumbing: a pool of connections, and a tiny migration runner.
--
-- A "migration" is one SQL file that changes the schema. Each is applied
-- once, in filename order, and recorded in a schema_migrations table so it
-- never runs twice.
module Ledger.Db
  ( newDbPool
  , waitForDatabase
  , retrying
  , runMigrations
  , migrationNames
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (Exception, try)
import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.FileEmbed (embedFile, makeRelativeToProject)
import Data.Pool (Pool, defaultPoolConfig, newPool, setNumStripes, withResource)
import Database.PostgreSQL.Simple
import Database.PostgreSQL.Simple.Types (Query (..))
import qualified Data.Text as T
import Ledger.Store (StoreUnavailable (..))
import Ledger.Store.Postgres (usingPool)

-- | Open a pool of up to 10 connections to the database at this URL, e.g.
-- "postgresql://USER:PASSWORD@HOST:PORT/DATABASE".
--
-- A pool keeps connections open and lends them out, because opening a new
-- connection for every request is slow. Requests borrow one with
-- withResource and give it back automatically when they're done.
newDbPool :: ByteString -> IO (Pool Connection)
newDbPool url =
  -- defaultPoolConfig create destroy idleSeconds maxConnections.
  --
  -- Every new connection gets a 5-second statement timeout: a query that
  -- runs longer is cancelled (and reported as the store being unavailable)
  -- instead of holding one of only 10 connections forever.
  -- By default the pool is split into one "stripe" per CPU core, each with
  -- its own share of the 10 connections, and a request can only borrow from
  -- its own stripe. On a 10-core machine that's 1 connection per stripe, so
  -- requests would queue while other connections sit idle. One stripe keeps
  -- all 10 connections available to everyone.
  newPool (setNumStripes (Just 1) (defaultPoolConfig openConnection close 60 10))
  where
    openConnection = do
      conn <- connectPostgreSQL url
      _ <- execute_ conn "SET statement_timeout = '5s'"
      pure conn

-- | Keep trying an action that can fail with exception e (only that type),
-- waiting between attempts: 0.5 s, then 1 s, 2 s, 4 s, then 5 s each time.
-- After the last attempt, its exception is thrown. "report" is told about
-- each failed attempt (the attempt number, starting at 1, and the error).
retrying :: Exception e => Int -> (Int -> e -> IO ()) -> IO a -> IO a
retrying attempts report action = go 1 500000
  where
    go n delay = do
      result <- try action
      case result of
        Right a -> pure a
        Left e
          | n >= attempts -> ioError (userError ("gave up after " <> show n <> " attempts: " <> show e))
          | otherwise -> do
              report n e
              threadDelay delay
              go (n + 1) (min 5000000 (delay * 2))

-- | Wait (about 40 seconds at most) until the database answers. A database
-- that's still starting, or a serverless one waking from sleep, is normal
-- at startup; without this the program would exit on the first failure.
waitForDatabase :: Pool Connection -> IO ()
waitForDatabase pool =
  -- usingPool turns every "can't reach it" failure (refused connection,
  -- "the database system is starting up", ...) into StoreUnavailable, so
  -- that's the one exception worth retrying; anything else is a real error.
  retrying 10 report $
    usingPool pool $ \conn -> do
      _ <- query_ conn "SELECT 1" :: IO [Only Int]
      pure ()
  where
    report :: Int -> StoreUnavailable -> IO ()
    report n (StoreUnavailable detail) =
      putStrLn ("Waiting for the database (attempt " <> show n <> "): " <> takeWhile (/= '\n') (T.unpack detail))

-- | Every migration, in the order it must be applied, as (file name, SQL).
--
-- "$( ... )" is a Template Haskell splice: the code inside runs while
-- compiling and its result (the file's contents) is pasted in here as if
-- you'd typed it. makeRelativeToProject finds the file relative to the
-- .cabal file, so it works whether you build from backend/ or the root.
--
-- Each file is listed by name on purpose. Embedding the whole folder would
-- miss NEW files: GHC only knows to recompile this module when a file it
-- already read changes, or when this module's own code changes. Adding a
-- line here is a code change, so a new migration is always picked up.
-- Ledger.MigrationsSpec fails if a file in db/migrations is missing here.
migrationFiles :: [(FilePath, ByteString)]
migrationFiles =
  [ ("0001_create_ledger.sql", $(embedFile =<< makeRelativeToProject "db/migrations/0001_create_ledger.sql"))
  , ("0002_users_and_sessions.sql", $(embedFile =<< makeRelativeToProject "db/migrations/0002_users_and_sessions.sql"))
  ]

-- | The names of every embedded migration, in order.
migrationNames :: [FilePath]
migrationNames = map fst migrationFiles

-- | Apply any migrations the database hasn't seen yet, and return their
-- names. Safe to call on every startup: already-applied files are skipped.
--
-- Everything runs in one transaction. Postgres can roll back schema changes
-- too, so if one migration fails, none of them are applied. The advisory
-- lock makes two servers starting at once take turns instead of both
-- trying to apply the same migration.
runMigrations :: Pool Connection -> IO [FilePath]
runMigrations pool = withResource pool $ \conn -> withTransaction conn $ do
  -- "Only" is postgresql-simple's one-column row. "Only ()" means one
  -- column we don't care about (pg_advisory_xact_lock returns void).
  _ <- query_ conn "SELECT pg_advisory_xact_lock(7243)" :: IO [Only ()]
  -- Hide Postgres's "already exists, skipping" notice on every restart.
  -- SET LOCAL only lasts until this transaction ends.
  _ <- execute_ conn "SET LOCAL client_min_messages TO warning"
  _ <-
    execute_
      conn
      "CREATE TABLE IF NOT EXISTS schema_migrations \
      \(version text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())"
  -- The "\" at the end of a line and the start of the next continues a
  -- string literal across lines.
  applied <- map fromOnly <$> (query_ conn "SELECT version FROM schema_migrations" :: IO [Only String])
  -- Keep only the files whose name isn't in the applied list.
  let pending = [(name, sql) | (name, sql) <- migrationFiles, name `notElem` applied]
  -- forM_ is a for-each loop over a list, running an action for each item.
  forM_ pending $ \(name, sql) -> do
    -- Query is a newtype around the SQL bytes; wrapping the file contents
    -- in it lets us run the whole file as one command.
    _ <- execute_ conn (Query sql)
    execute conn "INSERT INTO schema_migrations (version) VALUES (?)" (Only name)
  pure (map fst pending)
