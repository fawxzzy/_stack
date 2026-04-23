# Fitness QA Local Loop

## Policy

- `_stack` is the only deploy boundary for Fitness.
- Git/Vercel auto-deploys stay disabled unless the owner explicitly asks to re-enable them.
- The Fitness repo owns app code and local render/auth checks.
- The reusable Fitness QA user is permanent. Do not create random throwaway Supabase users.
- Credentials are never committed. Keep `FITNESS_QA_EMAIL`, `FITNESS_QA_PASSWORD`, and `SUPABASE_SERVICE_ROLE_KEY` in local env only.

## Local env

Set these in `repos/fawxzzy-fitness/.env.local` or the current shell:

```bash
NEXT_PUBLIC_SUPABASE_URL=...
NEXT_PUBLIC_SUPABASE_ANON_KEY=...
SUPABASE_SERVICE_ROLE_KEY=...
FITNESS_QA_EMAIL=...
FITNESS_QA_PASSWORD=...
APP_URL=http://127.0.0.1:3000
```

Optional:

```bash
HISTORY_QA_PREVIEW_ENABLED=1
FITNESS_QA_JUNK_USER_REGEX=codex.*fitness.*qa
FITNESS_QA_LOCAL_BASE_URL=http://127.0.0.1:3000
```

## Reusable QA user workflow

Run from `repos/fawxzzy-fitness`:

```bash
npm run qa:user:ensure
npm run qa:user:reset
npm run qa:session
```

`qa:user:ensure` creates or updates only the configured permanent Fitness QA user.

`qa:user:reset` deletes only app data owned by that QA user, then seeds a deterministic baseline routine and completed history session.

`qa:session` signs in as the QA user and writes a local cookie/session artifact under `runtime/fitness/`.

## Cleanup old junk users

Cleanup is dry-run by default and requires a Codex-specific safe pattern:

```bash
npm run qa:user:cleanup -- --pattern "codex.*fitness.*qa"
npm run qa:user:cleanup:apply -- --pattern "codex.*fitness.*qa"
```

The cleanup command refuses patterns that do not contain `codex`, skips the permanent QA account, and deletes only matched Supabase auth users.

## Instant feedback loop

Terminal 1:

```bash
cd repos/fawxzzy-fitness
npm run qa:dev
```

Terminal 2:

```bash
cd repos/fawxzzy-fitness
npm run qa:loop
```

This resets the QA account, signs in, and runs fast Edge/CDP captures for:

- `/login`
- `/entry`
- `/today`
- `/history`
- `/history/exercises`
- `/history/[sessionId]`

Artifacts are written to `tmp/captures/fitness/qa-local-feedback/`.

If `npm run build` or `npm run verify:strict` ran while the QA dev server was already open, restart `npm run qa:dev` before running the local loop again. Next dev and production builds share `.next`, so a long-lived dev server can briefly serve stale chunk paths after a production build.

## Supabase env mismatch diagnosis

Use `npm run qa:dev`; do not call `next dev` directly. The wrapper pins browser and server Supabase env from `repos/fawxzzy-fitness/.env.local`.

If local auth succeeds but server routes redirect to `/login`, check:

- `NEXT_PUBLIC_SUPABASE_URL` is identical for browser and server runtime.
- `NEXT_PUBLIC_SUPABASE_ANON_KEY` matches the same Supabase project.
- The dev server was restarted after env changes.
- `FITNESS_QA_LOCAL_BASE_URL`, if set, points to the same `127.0.0.1` origin used by the browser loop.

## Deploy checks

Before deploy:

```bash
cd repos/_stack
pnpm run fitness:doctor
pnpm run fitness:deploy:preflight
```

These checks block wrong repo boundaries, wrong Vercel links, Git auto-deploy drift, missing required env, and missing QA config.
