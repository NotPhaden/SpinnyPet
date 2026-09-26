# SpinnyPet build status

This package is the current V11 source build.

Validated locally:
- `src/App.jsx` TypeScript/JSX transpile check: OK
- `src/components.jsx`: OK
- `src/api.js`: OK
- `src/betaAuth.js`: OK
- `src/cases.js`: OK
- No runtime `Cosmic Value` / `cosmic_value` references remain in `src/` or the PS99 sync script.

The full Vite production build was not executed in this environment because `npm install` timed out before dependencies could be installed. Run `npm install` and then `npm run build` on the Windows machine before deployment.
