# SpinnyPet Supabase SQL order

## Existing database

Run only:

1. `FINAL_FIX.sql`
2. On your PC, after `.env` is configured: `npm run sync:ps99`

## Fresh database

Run:

1. `schema.sql` (includes the V12 gameplay patch at the end)
2. On your PC, after `.env` is configured: `npm run sync:ps99`

`reset_beta_demo.sql` is optional and only clears disposable beta data.

## Important

The SQL files contain SQL only. Do not paste this Markdown file into Supabase SQL Editor. The old migration files that enforced third-party value constraints were removed from this build to avoid accidentally restoring the previous Cosmic Value behavior.


### Quick patch for an already-working database
Run `supabase/LATEST_PATCH.sql` in the Supabase SQL editor to apply the current fixes.

### V12 gameplay patch
The current build adds:
- separate `/cases/<case-id>` pages for every case;
- multi-pet match creation;
- joining pet matches with your own pet bundle (no exact host variant requirement);
- safe variant-aware inventory decrements that never write quantity `0`;
- an upgrader that accepts the selected pet variants;
- a draggable risk wheel whose selected win sector is used by the server result.

`FINAL_FIX.sql` and `LATEST_PATCH.sql` already include the V12 SQL at the end. If your database already has the previous patch applied, run `LATEST_PATCH.sql` once more.

After the SQL is applied:
1. Configure `.env` with the Supabase URL and anon key.
2. Run `npm install`.
3. Run `npm run build`.
4. Deploy the `spinnypet-v9` folder to Vercel. `vercel.json` already rewrites application routes to `index.html`.



### V21.3 FINAL FIXES
Run `V21.3_FINAL_FIXES.sql` after `V21.2_FINAL_FIXES.sql`. The V21.3 file now ends with the V21.4 Clan treasury + persistent giveaway-state patch. This patch contains the final UI-supporting RPCs, automatic Time Rewards, automatic Clan Top-1 payout worker, official case tier routing, and Case Battle reward routing.

- V21.4.1_FINAL_FIXES.sql — hard fixes for Color Dice, Case Battle opening reels, persistent Giveaways, Time Rewards route/UI, Clans Top Clans RPC and treasury behavior.
