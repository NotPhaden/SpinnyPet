# SpinnyPet V24 Stable

Built from the known-good V23 frontend instead of layering the broken V24 frontend changes.

## Fixed
- Pet Plinko now animates every server-selected L/R step to the bottom gate; server multiplier is derived from the final gate.
- Pet Crash recovers an active round after refresh, automatically settles expired rounds, and returns a JSON crash result instead of throwing after marking the row crashed.
- Admin Abuse reward updates use explicit primary-key WHERE clauses row-by-row.
- Case Battle join automatically uses the host bundle when the client sends an empty case array. Each reward has an explicit round number.
- Live Coinflip / Color Dice pet wagers show the actual pet bundle alongside total diamond value.
- Existing V23 routes/components were kept as the base to avoid the V24 regression that hid/broke existing pages.

## Validation
- Frontend source is based on V23, which already produced a successful Vite build in the user environment.
- New SQL is additive/idempotent and replaces only the affected V23/V24 RPCs.
- `.env` is intentionally not included in the release archive.


## Match/Plinko stabilization pass
- Live pet wagers now render real PetIcon thumbnails instead of text-only labels.
- Case Battle rounds use the shared server `battle_started_at` clock so both clients advance/finish on the same timeline.
- Plinko now uses 14 server-side L/R decisions and 14 visual rows so the chip travels to the bottom gate.
