# V24 FIX

- Pet Plinko now visibly follows the server-selected L/R path before showing the multiplier.
- Pet Crash no longer rolls back the `crashed` status when cashout arrives after the crash point, so a new round can start.
- Admin Abuse reward update now has an explicit WHERE clause.
- Case Battle rewards now carry explicit round numbers for both players.
- Live pet matches show the actual staked pet names in addition to total diamond value.

Run `supabase/V24_FIX_PATCH.sql` after V22.7 and V23 SQL.
