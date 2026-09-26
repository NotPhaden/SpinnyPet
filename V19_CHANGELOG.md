# SpinnyPet V19 — Final Game, Rewards & UI Fixes

## Case Battle
- Joining a battle no longer asks the second player to select cases.
- The host's exact case bundle is displayed and is automatically reused for both sides.
- The joiner pays the same total diamond wager.
- Server-side settlement opens the exact same case sequence for both players and awards the full reward pool to the higher RAP total.

## Cases
- Opening reel now puts the authoritative server reward exactly under the final marker position.
- Case artwork on the catalog is smaller and keeps the supplied 1024×826 aspect ratio without cropping.
- Opening modal is narrower/shorter so it stays inside the content area instead of pushing into chat.

## Admin
- Added missing frontend imports for `betaAdminRemovePet`, `betaAdminClearInventory`, and `betaAdminAddPet`.
- Selected player inventory controls can now call their RPCs instead of throwing `is not defined`.
- Existing Give All behavior remains all-accounts when the target is blank.

## Time Rewards
- Replaced the old Daily Case page in navigation with Time Rewards.
- Unlock chain: Basic (30m) → Lucky (60m) → Titan (120m) → Cosmic (240m) → Omega (480m).
- Only one stage can be claimed at a time; the next stage unlocks only after the previous stage was claimed.
- Each stage gives a free case ticket.
- Free tickets open through a server-side reward function using the same case reward compositions.

## Live Bets
- Coinflip and Color Dice rooms include open and recent finished activity.
- Upgrader losses display as negative payout values.

## Navigation / UI
- Removed the top Wallet button.
- Removed the duplicate top Giveaway icon so Giveaways has one clear top action.
- Added a cohesive visual polish pass for cases, case battle, time rewards, live bets and match rows.
- Diamond stake input remains `bigint` based with no artificial 100B maximum; a 1T quick option was added as a convenience, not a cap.
