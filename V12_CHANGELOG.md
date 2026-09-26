# V12 gameplay fixes

- Each case now has a dedicated `/cases/<id>` route/page.
- Match creation supports selecting multiple pet variants.
- Joining a pet match lets the joining player choose their own pet bundle; the host's exact pet/variant is no longer required.
- Match pet bundles are stored atomically in `stake_pet_items`.
- Inventory decrements are variant-aware and remove rows at zero to satisfy `quantity > 0`.
- Upgrader accepts the selected inventory variant and uses `beta_run_upgrade_v3`.
- Upgrader risk wheel supports pointer/touch drag and the selected win sector is used by the server-side result.
- Vercel SPA rewrites remain configured in `vercel.json`.

Supabase:
- `supabase/V12_GAMEPLAY_FIX.sql` is the standalone patch.
- `FINAL_FIX.sql`, `LATEST_PATCH.sql`, and `schema.sql` include the patch at the end.
