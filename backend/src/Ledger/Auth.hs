-- | Who may do what. Pure functions, with no IO and no HTTP, so every rule
-- is easy to read and to test (see test/Ledger/AuthSpec.hs).
--
-- Ledger.App calls these after working out who is logged in, and before
-- touching the store.
module Ledger.Auth
  ( canView
  , canSendFrom
  , canDeposit
  , canOpenAccountFor
  ) where

import Ledger.Types

-- | Admins can see every account; customers only their own.
canView :: User -> Account -> Bool
canView user account = isAdmin user || owns user account

-- | Only an account's owner may send money out of it. Not even an admin:
-- admins bring money IN (deposits) but can't move customers' money around.
-- System accounts like "external" have no owner, so nobody can send from
-- them directly.
canSendFrom :: User -> Account -> Bool
canSendFrom = owns

-- | Only admins can bring money into the ledger from outside.
canDeposit :: User -> Bool
canDeposit = isAdmin

-- | Customers can open accounts for themselves; admins for anyone.
canOpenAccountFor :: User -> Username -> Bool
canOpenAccountFor user owner = isAdmin user || userName user == owner

-- Helpers ------------------------------------------------------------------

isAdmin :: User -> Bool
isAdmin user = userRole user == RoleAdmin

-- | "Just (userName user)" wraps the name so it can be compared with the
-- account's "Maybe Username" owner. An unowned account (Nothing) never
-- matches.
owns :: User -> Account -> Bool
owns user account = accountOwner account == Just (userName user)
