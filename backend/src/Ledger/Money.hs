-- LANGUAGE pragmas switch on optional compiler features ("extensions") for
-- this file only. Many everyday Haskell features are extensions like these.
--
-- DerivingStrategies lets us say HOW to derive an instance (see
-- "deriving newtype" below). GeneralizedNewtypeDeriving lets a newtype reuse
-- the instances of the type it wraps.
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

-- | Money is never a Double. We store integer cents and make it impossible
-- to build a negative or zero amount by accident.
--
-- (Comments starting with "-- |" are documentation comments, like JSDoc's
-- /** ... */. Plain "--" comments are ordinary comments.)
--
-- A module is one file. Its name must match its path under src/:
-- Ledger.Money lives in src/Ledger/Money.hs.
--
-- The list in parentheses is the export list: the only names other modules
-- can see. Anything not listed is private to this file.
module Ledger.Money
  ( Cents (..) -- the type AND its constructor: anyone can write "Cents 500"
  , Amount -- the type only, NOT its constructor (see "smart constructor" below)
  , unAmount
  , mkAmount
  ) where

-- Import only the two names we need from the aeson (JSON) library.
-- FromJSON and ToJSON are type classes: think "interfaces" in TypeScript.
import Data.Aeson (FromJSON, ToJSON)

-- | A signed quantity of cents. Balances can be negative (the external
-- funding account goes negative when money enters the system), so this type
-- allows any integer.
--
-- "newtype Cents = Cents Integer" reads as: define a new type called Cents,
-- built with a constructor also called Cents, that holds one Integer.
-- (Integer is Haskell's unlimited-size whole number, so no overflow.)
--
-- A newtype costs nothing at runtime, but the compiler treats Cents and
-- Integer as different types, so you can't mix them up by accident.
newtype Cents = Cents Integer
  -- "deriving" asks the compiler to write instances for us:
  --   Eq   -> == and /=
  --   Ord  -> <, >, compare (needed for sorting and "balance < amount")
  --   Show -> turn a value into a String for printing/debugging
  deriving (Eq, Ord, Show)
  -- "deriving newtype" reuses Integer's own instances:
  --   Num      -> +, -, * and number literals, so "Cents 5 + Cents 3" and
  --               even a bare "500" work wherever Cents is expected
  --   ToJSON / FromJSON -> encode as a plain JSON number, e.g. 500
  deriving newtype (Num, ToJSON, FromJSON)

-- | A strictly positive amount of money to move. The constructor is not
-- exported, so the only way to get an 'Amount' is through 'mkAmount', which
-- checks the invariant once, at the edge of the system.
--
-- This is the "smart constructor" pattern. Because other modules can't write
-- "Amount (Cents (-5))", holding an Amount is PROOF the number is > 0.
newtype Amount = Amount Cents
  deriving (Eq, Ord, Show)

-- The line with "::" is a type signature: "unAmount takes an Amount and
-- returns Cents". In TypeScript: (a: Amount) => Cents.
unAmount :: Amount -> Cents
-- Pattern matching: "(Amount c)" unwraps the Amount and names what's inside
-- "c". Then we simply return c. No "return" keyword: the right-hand side of
-- "=" IS the result.
unAmount (Amount c) = c

-- Maybe is how Haskell says "might be missing", instead of null:
--   Just x   -> there is a value x
--   Nothing  -> there isn't
-- Callers are forced to handle both cases; the compiler won't let them
-- forget the Nothing case.
mkAmount :: Integer -> Maybe Amount
mkAmount n
  -- These "|" lines are guards: an if / else-if chain. The first condition
  -- that is True wins. "otherwise" is just another name for True.
  | n > 0 = Just (Amount (Cents n))
  | otherwise = Nothing
