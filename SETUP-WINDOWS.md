# SpinnyPet Windows setup

## 1. Install

```powershell
npm install
npm run dev
```

Open `http://localhost:5173/`.

## 2. Supabase

Create `.env` next to `package.json`:

```env
VITE_SUPABASE_URL=https://YOUR_PROJECT.supabase.co
VITE_SUPABASE_PUBLISHABLE_KEY=YOUR_PUBLISHABLE_KEY
SUPABASE_SERVICE_ROLE_KEY=YOUR_SERVICE_ROLE_KEY
```

Never expose `SUPABASE_SERVICE_ROLE_KEY` in client code or Git.

Run `supabase/schema.sql` in Supabase SQL Editor. If you already ran an older SpinnyPet schema, run `supabase/FINAL_FIX.sql` afterward too.

## 3. PS99 catalog + RAP sync

After `.env` is configured:

```powershell
npm run sync:ps99
```

The site keeps every Huge/Titanic/Gargantuan row from the PS99 catalog. A pet with 0/unknown RAP remains visible and selectable; it is only shown as NOT PRICED until RAP is available.

## 4. Staff roles

See `STAFF-SETUP.md`.

## 5. Roblox

Profile accepts an exact Roblox username, numeric User ID, or a `roblox.com/users/<id>/profile` URL.

### If Supabase reports `syntax error at or near "||"`

Use the corrected SQL files from this package. PostgreSQL `RAISE EXCEPTION` uses a format string, so the ban/mute messages are written as `RAISE EXCEPTION '... %', value` rather than string concatenation inside the `RAISE` statement.

Recommended order:
1. Fresh project: run `supabase/schema.sql` only.
2. Existing older project: run `supabase/FINAL_FIX.sql` after the old schema.
3. Do not run legacy migration files for a fresh install. This build intentionally ships only `schema.sql`, `FINAL_FIX.sql`, and the optional demo reset.
4. Optional demo reset: run `supabase/reset_beta_demo.sql` after the schema exists.
