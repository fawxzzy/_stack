# Mazer Preview Recovery Receipt

Date: 2026-04-20
Lane: deploy/preview recovery only
Classification: platform blocker

## Scope

- No app code changed.
- No architecture/product work reopened.
- Local repo health was treated as the baseline gate before retrying hosted preview deploys.

## Local Baseline

- Repo: `repos/fawxzzy-mazer`
- Command: `npm run verify`
- Result: passed
- Notes:
  - `318` tests passed.
  - Production build completed cleanly.
  - The repo stayed green before hosted deploy retries.

## Hosted Deploy Attempts

Command used from `repos/_stack`:

```text
pnpm run mazer:deploy:preview
```

Attempt 1

- Start: `2026-04-20T15:34:58.5537909-04:00`
- End: `2026-04-20T15:43:01.5971545-04:00`
- Exit code: `1`
- Inspect URL: none created
- Final preview URL: none created
- Failure stage: after upload, before hosted build/preview creation
- Raw log: `tmp/mazer-preview-recovery/20260420-153458/deploy.log`
- Meta: `tmp/mazer-preview-recovery/20260420-153458/meta.txt`

Attempt 2

- Start: `2026-04-20T15:43:42.8825783-04:00`
- End: `2026-04-20T15:56:40.2610545-04:00`
- Exit code: `1`
- Inspect URL: none created
- Final preview URL: none created
- Failure stage: after upload, before hosted build/preview creation
- Raw log: `tmp/mazer-preview-recovery/20260420-154342/deploy.log`
- Meta: `tmp/mazer-preview-recovery/20260420-154342/meta.txt`

Repeated Vercel error on both attempts:

```text
FetchError: invalid json response body at https://api.vercel.com/v2/files?teamId=team_CMJn7MvzFZZBnhNnjVUZF2RD reason: Unexpected end of JSON input
```

## Latest Ready Preview Comparison

- Latest ready preview listed during this run:
  - `https://fawxzzy-mazer-nv0hnemg3-zachariah-redfields-projects.vercel.app`
- Deployment list capture:
  - `tmp/mazer-preview-recovery/handoff-20260420-1605/vercel-ls.txt`

Hosted probe result against the latest ready preview:

- Probe URL:
  - `https://fawxzzy-mazer-nv0hnemg3-zachariah-redfields-projects.vercel.app/?content=core-only&theme=aurora&runtimeDiagnostics=1`
- Result:
  - HTTP `401`
  - No runtime diagnostics became available in this automation context
  - The response resolved to a Vercel auth/login surface instead of the app
- Probe artifact:
  - `tmp/mazer-preview-recovery/handoff-20260420-1605/hosted-probe.json`

## Conclusion

- Local verify/build remained green.
- Two hosted deploy retries failed with the same post-upload Vercel API/file response error.
- No fresh hosted preview was created, so the hosted watch/play closure gate could not be completed on a fresh deploy.
- This should be treated as a Vercel/platform blocker, not a repo blocker.
- Stop repo changes for architecture freeze sign-off until preview creation works again.
