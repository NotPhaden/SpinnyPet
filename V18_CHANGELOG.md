# SpinnyPet V18 — Game + UI Fixes

- Fixed `betaJoinLobby is not defined` in Color Dice by importing the function.
- Color Dice Create Match opens with **0 preselected colours**; player must choose exactly 2. Join also starts empty.
- Fixed exact-stack inventory consumption in Upgrader / lobby joins so `quantity > 0` check is never violated.
- Upgrader result now reliably returns a loss and consumes the exact input stack; frontend refreshes inventory after result.
- Added `beta_admin_get_inventory` RPC and wired Admin Panel inventory loading for selected players.
- `Give All Players` now grants the high-tier catalog to **every registered beta account** when no username is supplied.
- Added `beta_live_bets()` for homepage Live Bets: Coinflip + Color Dice open rooms + recent Upgrader results.
- Coinflip result/reveal animation lasts about 15 seconds before showing the final side.
- Case listing artwork frame now follows the supplied image ratio (`1024x826`) instead of cropping the artwork.
- Case opening popup is narrower and height-limited so it does not visually spill toward the chat column.
- Added V18 SQL patch and complete SQL installer.

Build note: `npm install` timed out in the verification environment, so a full Vite build could not be completed here. JavaScript balance/syntax checks passed for `betaAuth.js`; App JSX delimiters are balanced.
