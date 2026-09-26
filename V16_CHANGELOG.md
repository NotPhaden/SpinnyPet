# SpinnyPet V16 — gameplay + missing pages fix

## Fixed
- Coinflip rebuilt around the requested Heads/Tails flow:
  - minimum 10M gems
  - Titanic + Gargantuan pets or gems only
  - multi-pet selection, Select All, Clear, search and sorting
  - server-side 50/50 resolution
  - winner receives the combined stake
  - result popup with winner and payout
- Removed Blackjack and Jackpot from the visible menu/home and their routes now fall back to Home.
- Added a real Home button to the sidebar.
- Added Home Live Bets table with `Game / Player / Bet / Multiplier / Payout`.
- Removed the Home High-tier pet market section.
- Added a real `/promo` page and admin promo-code creator.
- Fixed Admin Panel blank-page failure by defining `PromoCodeAdmin` and keeping an explicit staff-access state.
- Added `beta_get_role` support in the existing-database patch flow (already present from V15).
- Upgrader now shows a Win/Lose result popup and clears consumed selections after a settled upgrade.
- Upgrader/inventory writes now use a safe positive-quantity helper and the quantity constraint is repaired before use.
- Case opening moved to a real modal animation + result popup; backend case rewards now use PS99 RAP and the exact configured case composition.
- Giveaway chat now supports previous/next switching across multiple active giveaways and keeps the selected winner visible for 10 seconds.
- Beta reward is now `50B + Random Titanic` once every 30 minutes instead of once per account.

## Supabase
For an existing database, run:
1. `supabase/FINAL_FIX.sql`

For a fresh database:
1. `supabase/schema.sql`

`supabase/LATEST_PATCH.sql` also contains the V16 patch set for an already-working database.

## Validation
- App.jsx balanced braces/parens/brackets.
- betaAuth.js balanced braces/parens/brackets.
- SQL files have balanced parentheses.
- Frontend RPC names are present in the SQL bundle.
- Full Vite build was not executed in this environment because `npm install` timed out.
