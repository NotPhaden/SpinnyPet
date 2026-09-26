# V20 — Case Battle Reveal + Opening + Time Rewards + UI Polish

- Case Battle now locks the creator's exact case bundle for the joiner.
- Case Battle has a cinematic two-column reveal: every case opens for Host and Joiner before the final winner is shown.
- Case Battle settlement remains server-authoritative; the animation is only the presentation layer.
- Case opening reel now measures the actual winning card and animates to that exact card instead of relying on a hard-coded pixel stop.
- Added original `public/assets/win.ogg` and win sound on player victories.
- Coinflip visual reveal reduced from 15 seconds to 5 seconds.
- Time Rewards always renders the full Basic → Lucky → Titan → Cosmic → Omega chain, even while API data is loading or a visitor is logged out.
- Time Rewards uses 30m / 1h / 2h / 4h / 8h sequential unlocks.
- Live Bets SQL UNION fixed so Upgrader rows include their wager column; losses are negative.
- Removed the wallet summary and duplicate topbar Giveaways button from the navbar.
- Added premium typography/theme polish based on the supplied reference HTML: Outfit, Syne, Nunito and Share Tech Mono plus asset reload recovery.
