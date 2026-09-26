# SpinnyPet verification notes

- Existing Supabase database: run `supabase/FINAL_FIX.sql`. Fresh database: `supabase/schema.sql` already contains the latest overrides.
- Run `npm run sync:ps99` after the SQL patch. The sync uses the BIG Games PS99 pet collection + official RAP endpoint only.
- Every Huge/Titanic/Gargantuan remains in the catalog, including entries with 0/unknown RAP; those entries are not locked.
- Upgrader uses PS99 RAP and lets the tester click the wheel to reposition the winning sector without changing the computed chance.
- Match lobbies store the exact pet variant, so golden/rainbow/shiny stakes are checked against the same variant on join/cancel.
- Cases start with artwork + `View Case`; the detail flow includes the idle `Opening your case…` reel, 1×–5×, `Open Case`, `Demo Open`, and a clean `Pets in this case` grid.
- Giveaway hosts cannot enter their own giveaways. The live chat card shows the reward pet image or diamonds.
- Admin Panel includes idempotent Give All plus per-player inventory clear/remove/add tools.
- Toast/info boxes are larger and easier to read.
