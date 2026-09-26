# SpinnyPet Beta

SpinnyPet is a private beta UI for virtual Pet Simulator 99 high-tier pet and diamond games.

## Catalog rules

The public catalog shows **Huge, Titanic, Gargantuan and Diamonds**. Every high-tier pet remains visible even when official PS99 RAP is 0 / not available. Zero-RAP pets are never locked from the catalog UI.

Pet images come from the BIG Games PS99 public API / image proxy. BIG Games documents `/api/*` as the supported game-data surface and the repository includes pet icons. See https://github.com/BIG-Games-LLC/ps99-public-api-docs

## Values

Pet pricing uses the official BIG Games PS99 **RAP (Recent Average Price)** feed. RAP is the numeric market reference used for stake calculations and display. For the full catalog, run the PS99 sync:

```bash
npm install
npm run sync:ps99
```

Set these only in your local shell or a private `.env` used by the sync script:

```env
VITE_SUPABASE_URL=https://YOUR_PROJECT.supabase.co
SUPABASE_SERVICE_ROLE_KEY=YOUR_SERVICE_ROLE_KEY
```

**Never expose `SUPABASE_SERVICE_ROLE_KEY` to Vite/browser code.**

The sync script reads the official BIG Games PS99 pet collection plus the official RAP endpoint and writes high-tier metadata/RAP into `pets_cache`. A zero/unknown RAP is stored as `0` and is never used to lock a pet out of the catalog.

## Beta economy

- New beta accounts can claim **50B diamonds + one random Titanic once**.
- Diamond inputs accept `k`, `m`, `b`, `t`: examples `250k`, `50m`, `1.5b`.
- Pets use official PS99 RAP for stake calculations.
- All currency is virtual beta currency. No Robux or real-money deposits/withdrawals are implemented.

## Beta accounts

There is **no email authentication**. Accounts are username + password only. Passwords are stored as bcrypt hashes using PostgreSQL `pgcrypto` and sessions are kept in a 30-day token table plus localStorage so a refresh does not log the tester out.

The profile supports a local picture upload or direct image URL. The custom avatar is stored on the beta account and copied into chat messages.

## Supabase

Run **`supabase/schema.sql` once** in Supabase SQL Editor. It includes the latest PS99-RAP, match-variant, upgrader, cases, giveaway, event and admin-inventory overrides in the same file. For an already-created database, run **`supabase/FINAL_FIX.sql`** to apply the same fixes without rebuilding the database. It contains:

- beta username/password accounts and sessions
- 50B beta bonus + random Titanic
- high-tier inventory
- PS99 pet/image cache
- PS99 RAP cache
- chat + realtime
- game lobby records
- site activity/history
- profile stats and ranks
- daily cases
- giveaways

For a clean disposable beta reset, run `supabase/reset_beta_demo.sql`.

## Routes

- `/`
- `/coinflip`
- `/dice`
- `/jackpot`
- `/blackjack`
- `/upgrader`
- `/cases`
- `/inventory`
- `/profile`
- `/daily-cases`
- `/giveaways`
- `/event`
- `/admin` (staff only)

Vercel and Netlify SPA rewrites are included so refreshing a nested route continues to work.

## Assets

`public/assets/` contains:

- `logo.png`
- `favicon.png`
- `coinflip.png`
- `dice.png`
- `jackpot.png`
- `blackjack.png`
- `upgrader.png`
- `daily-case.png`

Replace those PNGs with your final art without changing the code.

## Run

```bash
npm install
npm run dev
```

## Supabase SQL order (important)

Use `supabase/schema.sql` for a fresh database. If you already have an older SpinnyPet database, run `supabase/FINAL_FIX.sql` afterward.

`FINAL_MIGRATION.sql` / `final_migration.sql` are kept as legacy migration copies; they are syntax-fixed, but they are not required for a fresh install.

`reset_beta_demo.sql` is optional and is safe to run even if the event/member tables were not created yet.

## Final 0.5.0 additions

- Fixed Roblox username resolution for usernames containing digits (for example `andr918` is no longer mistaken for User ID `918`). Numeric IDs and `roblox.com/users/ID/profile` URLs still work.
- Game banner art now uses dedicated `*background.png` assets.
- Coinflip/Dice/Jackpot/Blackjack Create + History controls are wired; History reads beta activity.
- Create Match modal was rebuilt so it is no longer clipped by the generic auth-modal width.
- Added `/cases` with case artwork-first browsing, View Case detail, 1×–5× opening, Demo Open and animated reel opening.
- Fixed pet giveaway SQL constraint so pet rewards can use `reward_amount = 0`.
- Fresh `schema.sql` now creates `pets_cache` before `beta_inventory`, so the core foreign key works on a truly fresh database.

## Legacy notes

- High-tier catalog keeps every Huge/Titanic/Gargantuan from the BIG Games catalog, including zero/unknown RAP entries; they stay selectable and are shown as NOT PRICED.
- `npm run sync:ps99` refreshes the full high-tier catalog and official PS99 RAP values.
- Bonus persistence is fixed: 50B + a random Titanic is saved server-side and survives refresh.
- Total virtual value = wallet diamonds + official PS99 RAP of all owned inventory quantities.
- Promo codes can be created by Owner/Co Owner/Manager/Admin and redeemed by players.
- Giveaways auto-finalize after their timer; the chat shows a live giveaway card with JOIN.
- Custom profile picture URL is supported when Roblox avatar sync is unavailable.
- Cases are under Games and show current possible reward pets before opening.


### Catalog behavior
The app bootstraps the complete Huge/Titanic/Gargantuan metadata catalog from BIG Games into `pets_cache` on load, while official PS99 RAP is refreshed by `npm run sync:ps99`. Zero/unknown RAP entries remain visible and selectable and display `NOT PRICED`.


### Current changes
- Third-party value sources are not used. Pet pricing is shown explicitly as `PS99 RAP`.
- Upgrader wheel now lets the tester click the wheel to reposition the same winning % sector without changing the probability.
- Match pet variants are stored in lobbies so joining a golden/rainbow/shiny stake no longer incorrectly checks the normal variant.
- Cases page shows only case artwork + `View Case`; the detail view contains an idle `Opening your case…` reel, 1x–5x controls, `Open Case`, `Demo Open`, then `Pets in this case`.
- Giveaway hosts cannot join their own giveaway; the chat giveaway card shows the actual pet image or diamond reward.
- Admin panel adds inventory clear/remove/add tools, and Give All grants every high-tier catalog pet without value-source filtering.
- Sidebar game icons use Lucide icons instead of the PNG game art.


### Value source
SpinnyPet no longer uses Cosmic Values. Pet prices shown by the app use the official BIG Games PS99 API RAP (Recent Average Price), expressed in diamonds. A RAP of `0` means the API has no RAP data for that item; the pet remains visible and selectable where the feature allows it.


