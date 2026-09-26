# SpinnyPet V17 – Gameplay Fixes

## Fixed
- Color Dice minimum wager is now **5B**.
- Color Dice join flow now lets the second player choose **their own 2 colors** instead of forcing the host colors.
- Color Dice resolves server-side on join, records the rolled color and winner, and returns/awards the wager correctly.
- Color Dice and Coinflip open-match lists poll automatically; new matches no longer require manual page refresh.
- Coinflip rows show a clear **Heads/Tails** badge and player avatar.
- Coinflip result popup is shown when the host's match is resolved, with the existing coin animation.
- Profile/custom avatar is copied to live open match rows and synced when the avatar changes.
- Upgrader result handling keeps the Win/Lose popup explicit and uses the safe inventory writer for both consuming inputs and awarding the target pet.
- Case artwork cards use a fixed visual frame so `case-basic.png`, `case-lucky.png`, `case-titan.png`, `case-cosmic.png`, and `case-omega.png` render at a consistent size.
- Added **Case Battle** page using the existing five cases. Players choose 1–5 cases, match the same total wager, open them server-side, and the higher combined RAP takes the generated rewards.
- Admin **Give All** now defaults to the logged-in admin if the target field is empty.
- Removed the extra empty-state **Open Coinflip** CTA from Live Bets.

## Supabase
Run `supabase/V17_GAME_FIXES.sql` after the V16 complete schema, or use `SUPABASE_SPINNYPET_V17_COMPLETE.sql` as the complete installer.

## Validation
- `src/App.jsx` delimiter counts balanced.
- `src/betaAuth.js` passes `node --check`.
- SQL delimiter balance is correct after stripping comments/string literals.
- Full Vite build was not completed because `npm install` timed out in the build environment.
