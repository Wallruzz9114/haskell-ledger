-- | Every SQL file in db/migrations must be listed in Ledger.Db, or it would
-- never be applied. This catches the easy mistake of adding a file and
-- forgetting the list.
module Ledger.MigrationsSpec (spec) where

import Data.List (isSuffixOf, sort)
import Ledger.Db (migrationNames)
import System.Directory (listDirectory)
import Test.Hspec

spec :: Spec
spec = do
  it "embeds every file in db/migrations, in name order" $ do
    -- cabal runs the tests from the package folder (backend/), so this
    -- relative path points at backend/db/migrations.
    onDisk <- filter (".sql" `isSuffixOf`) <$> listDirectory "db/migrations"
    migrationNames `shouldBe` sort onDisk
