-- | The TypeScript types the front end imports must match the Haskell ones.
--
-- If someone changes a type in Ledger.Api (or Ledger.Types) without
-- regenerating web/src/app/generated/apiTypes.ts, this test fails and says
-- how to fix it. CI runs it on every pull request.
module Ledger.TypeScriptSpec (spec) where

import Ledger.Api (apiTypeScript)
import Test.Hspec

spec :: Spec
spec =
  it "matches web/src/app/generated/apiTypes.ts (regenerate it if not)" $ do
    -- cabal runs the tests from backend/, so the front end is one level up.
    onDisk <- readFile "../web/src/app/generated/apiTypes.ts"
    -- Compare line by line: a failure then shows which lines differ.
    lines onDisk `shouldBe` lines apiTypeScript
