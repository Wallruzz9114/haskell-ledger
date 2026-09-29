-- | The test suite's entry point, generated for us.
--
-- This one line tells GHC to run the file through "hspec-discover" before
-- compiling it. hspec-discover finds every module under test/ whose name
-- ends in "Spec" (Ledger/MoneySpec.hs, Ledger/CoreSpec.hs, ...), and writes
-- a main that runs each one's "spec", grouped under its module name.
--
-- So adding tests means adding a new FooSpec.hs file with a "spec :: Spec",
-- and listing it in the cabal file's other-modules. Nothing else to wire up.
{-# OPTIONS_GHC -F -pgmF hspec-discover #-}
