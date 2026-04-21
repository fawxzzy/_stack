# Mazer Hosted Preview Verification

Date: 2026-04-21
Lane: final hosted preview verification
Classification: healthy-but-held

## Scope

- No app code changed in this pass.
- The goal was to run the normal `_stack` hosted preview flow and close the final real-device/manual lane if the deployment and browser context allowed it.

## Local Baseline In Session

Repo: `repos/fawxzzy-mazer`

Previously completed in this same closure lane before the hosted pass:

1. `npx vitest run tests/render/intentFeedRenderer.test.ts tests/scenes/menu-intent-runtime.test.ts tests/scenes/demo-build.test.ts tests/boot/install-surface.test.ts`
2. `npm run visual:matrix -- --preset core --skip-build true`
3. `npm run edge:live -- --skip-build true --headless true --run core-only-watch`
4. `npm run edge:live -- --skip-build true --headless true --run core-only-play`
5. `npm run verify`

Result:

- Local repo-owned proof was green before the hosted pass.

## Hosted Preview Flow

Run from: `repos/_stack`

### Deploy preflight

Command:

```text
pnpm run mazer:deploy:preflight
```

Result:

- Passed for `Zachariah Redfield <zjhredfield@icloud.com>`.

### Preview deploy

Command:

```text
pnpm run mazer:deploy:preview
```

Result:

- Passed.
- Inspect URL:
  - `https://vercel.com/zachariah-redfields-projects/fawxzzy-mazer/ALHC9F3uBhd7kyBByb5NKeKJpgpg`
- Preview URL:
  - `https://fawxzzy-mazer-ldziqap6p-zachariah-redfields-projects.vercel.app`

## Hosted Verification Evidence

### Authenticated CLI fetch

Command:

```text
pnpm dlx vercel --cwd ../fawxzzy-mazer curl "/?content=core-only&theme=aurora&runtimeDiagnostics=1" --deployment https://fawxzzy-mazer-ldziqap6p-zachariah-redfields-projects.vercel.app
```

Result:

- Returned the deployed app document successfully through deployment protection.
- Confirmed the hosted document points at the current shell:
  - title `Mazer`
  - favicon `/icons/mazer-emblem.svg`
  - apple touch icon `/icons/icon-192.png`
  - manifest `/manifest.webmanifest`
  - current main bundle `/assets/main--QUzT-2u.js`

### Hosted manifest check

Command:

```text
pnpm dlx vercel --cwd ../fawxzzy-mazer curl /manifest.webmanifest --deployment https://fawxzzy-mazer-ldziqap6p-zachariah-redfields-projects.vercel.app
```

Result:

- Returned the current manifest successfully.
- Confirmed:
  - `name` and `short_name` are `Mazer`
  - `display` is `standalone`
  - `theme_color` and `background_color` are `#101018`
  - icon set includes:
    - `/icons/icon-192.png`
    - `/icons/icon-512.png`
    - `/icons/icon-192-maskable.png`
    - `/icons/icon-512-maskable.png`
    - `/icons/mazer-emblem.svg`

### Hosted error log check

Command:

```text
pnpm dlx vercel --cwd ../fawxzzy-mazer logs --deployment https://fawxzzy-mazer-ldziqap6p-zachariah-redfields-projects.vercel.app --no-follow --level error --since 30m --no-branch
```

Result:

- No logs found for the deployment during the queried window.

## Browser Attempt

Browser/mode used:

- Automated desktop Edge/Chromium context
- Hosted preview URL

Result:

- Direct browser navigation did not reach the app.
- Vercel redirected the automation context to:
  - `https://vercel.com/login?...`
- The browser landed on `Login – Vercel`.
- Runtime diagnostics and visual diagnostics were unavailable because the app shell itself was not reached in that unauthenticated browser context.

Classification:

- Manual/authenticated hosted browser gate still required.
- This is not evidence of a repo or runtime regression.

## Closure State

- Repo-owned local proof: green
- Hosted preview deploy: green
- Hosted authenticated CLI fetch: green
- Hosted browser/device pass:
  - held on Vercel Authentication in the automation context

Remaining manual closure items:

1. Phone Safari pass on the deployed preview.
2. Installed PWA / Add to Home Screen pass.
3. Desktop watch pass on the deployed preview.
4. Desktop Tab-to-play pass on the deployed preview.

Current lane description:

- `healthy-but-held`

