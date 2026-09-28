# V23 Games Update

Implemented three playable server-settled games:

- **Pet Mines** — 5x5 board, 3 hidden mines, progressive multiplier and cash-out.
- **Pet Plinko** — animated drop path with server-selected multiplier gates.
- **Pet Crash** — live multiplier with server-hidden crash point and server-validated cash-out.

### Security/economy
- New game state is stored in `beta_v23_games`.
- Bets are deducted server-side.
- Payouts are credited server-side.
- Mines are generated server-side.
- Crash cash-out is validated from server time and the hidden crash point.
- Browser input cannot choose a payout or outcome.

### Install
Run `supabase/V23_GAMES_UPDATE.sql` after the V22.7 update, then deploy the frontend.

V23 currently uses diamond stakes for the three new games. Existing Coinflip, Color Dice and Case Battle pet support remains unchanged.
