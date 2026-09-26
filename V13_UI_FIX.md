# V13 UI / Interaction Fixes

- Case navigation now keeps the selected case in React state as well as the URL, so clicking `View` immediately renders `/cases/<id>` without requiring a refresh.
- Browser back/forward updates the selected case state.
- Case detail was polished into a larger hero/opening layout inspired by the supplied reference page.
- Upgrader wheel now starts its visual spin immediately when `Upgrade` is clicked, instead of waiting for the RPC response.
- The wheel's risk position is draggable and the wheel uses a real CSS transform animation for the 6.5s spin.
- Backend win/loss remains authoritative; the animation is only the visual presentation.
- Added touch-action/user-select protection so dragging the wheel does not drag the page/image.
