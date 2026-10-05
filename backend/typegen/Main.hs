-- | "ledger-typescript": print the TypeScript types for the API.
--
-- From the repository root:
--   cabal run -v0 ledger-typescript > web/src/app/generated/apiTypes.ts
--
-- All the work is in Ledger.Api; this program only prints the result.
module Main (main) where

import Ledger.Api (apiTypeScript)

main :: IO ()
main = putStr apiTypeScript
