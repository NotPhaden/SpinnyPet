# SpinnyPet V22 FINAL

- Removed the 1X/2X/3X/4X case opening selector. Cases now have only `Open Case` and `Demo Open`, one case per click.
- Reworked Case Battle opening animation to use a deterministic CSS reel matching the Cases-style reel, avoiding DOM-measurement timing glitches.
- Case Battle now advances cleanly Round 1, Round 2, etc. for multi-case battles and clears all delayed timers when closed.
- Case Battle modal is constrained to its own viewport and no longer creates horizontal overflow into the chat area.
- Color Dice lobby/history state is defensive against malformed/non-array responses and hides the player's own created lobby from the public join list.
- No Clan Battle/database gameplay logic was changed.
