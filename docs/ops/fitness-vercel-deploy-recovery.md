# Fitness Vercel Deploy Recovery

## Purpose

This runbook is the canonical recovery lane for Fitness production deploys when Vercel identity, repo linkage, or deployment plumbing drifts.

Fitness deploys are manual-only from `_stack`. Git/Vercel auto-deploy creation must remain disabled unless the owner explicitly requests re-enabling it.

## Canonical hosting identity

- Team ID: `team_CMJn7MvzFZZBnhNnjVUZF2RD`
- Current team slug: `fawxzzy`
- Project ID: `prj_rtlFVOMFAWCRoJ3SQjHloi89881K`
- Current project name: `fawxzzy-fitness`

Rule: Hosting identity checks must validate immutable team/project IDs, not only mutable slugs or display names.

Pattern: Use connector-confirmed project identity as source of truth, then mirror that identity into `_stack` deploy guards and local link metadata.

## Standard recovery lane

1. Use the Vercel connector first.
   - List accessible teams.
   - Inspect the expected team ID and project ID.
   - Record the current human-readable slug/name returned by Vercel.
2. Confirm local repo linkage in `..\fawxzzy-fitness\.vercel\project.json`.
   - `orgId` must match the canonical team ID.
   - `projectId` must match the canonical project ID.
   - `projectName` should match the current project name.
3. Run the `_stack` guard before any production deploy.

```powershell
cd repos/_stack
pnpm run fitness:deploy:preflight
```

4. Confirm Git auto-deploy creation is disabled.
   - Expected Vercel API state: `gitProviderOptions.createDeployments = disabled`.
   - If it drifted, run `pnpm run fitness:git:autodeploy:disable` from `_stack`, then rerun preflight.
   - Do not deploy while Git auto-deploys are enabled.
5. Classify any mismatch exactly:
   - Team ID mismatch: wrong Vercel account or wrong team link.
   - Project ID mismatch under the correct team ID: wrong project link.
   - Matching team/project IDs with mismatched slug/name: rename drift. Update checked-in config to the connector-confirmed current slug/name.
6. Verify targeted env coverage only after identity is confirmed.

```powershell
pnpm run fitness:doctor
```

7. Run the repo-local verification lane from `..\fawxzzy-fitness`.

```powershell
npm run verify
npm run verify:mobile-regression
npm run verify:strict
```

8. Deploy production from the canonical linked project.

```powershell
cd repos/_stack
pnpm run fitness:deploy:prod
```

9. If the deployment fails, inspect the same deployment through the Vercel connector first, then the local CLI if more detail is needed.

## Manual deploy-only policy

- Do not deploy Fitness from `repos/fawxzzy-fitness` directly.
- Do not rely on Git push to create Fitness deployments.
- Use `_stack` scripts for preview, production, prebuilt, and logs variants.
- `_stack` preflight must pass before any Fitness deploy command calls Vercel.
- Re-enabling Git auto-deploys is an owner-requested change, not an incident workaround.

## Current observed rename drift

Historical deployment URLs and aliases still include old owner strings such as `zachariah-redfields-projects` and `zachariahredfield`. Those strings are historical URL artifacts, not the canonical project identity.

Failure Mode: A team rename makes local slug-based checks lie, causing false “wrong owner” failures even though the underlying Vercel project is the right one.

## Current observed prod failure signature

The April 22, 2026 failures on `dpl_2fzEin29DSRrPgnGeMiVdnCrp9bZ` and `dpl_GqooCHhjcLCRkEi27idz8Yms15eh` both targeted the canonical Fitness project and returned:

- production target
- correct project ID
- deployment state `ERROR`
- build surface `. [0ms]`
- Vercel CLI message `Unexpected error. Please try again later.`
- connector build-log access failure `401 unauthorized`

Interpretation: treat this as deployment plumbing or Vercel platform failure until logs prove an application build failure. Do not mutate app code based on this signature alone.

## Windows prebuilt caveat

Failure Mode: Prebuilt deploy fallback on Windows can fail on symlink packaging; do not diagnose app code from that alone.

If a Windows prebuilt deploy fails after local verify/build succeeds, classify that separately from remote-build failures and use it only as packaging evidence, not as proof that the app is broken.

## Incident chain captured on 2026-04-22

Failure Mode: A mounted app folder under ATLAS inherits the parent repo boundary and poisons git recovery unless recloned as a real standalone repo.

- Fake repo boundary under `<ATLAS_ROOT>` made the app look recoverable in-place when it was not.
- Wrong Git origin history compounded the lane replay until the repo was recloned as a real standalone repo.
- Shared UI/type drift surfaced while replaying the release lane and had to be cleaned before deploy verification was trustworthy.
- Vercel owner/slug confusion obscured the real issue because old owner strings remained visible in deployment URLs after the rename.
- Mutable slug vs immutable ID is the key lesson: `teamId` and `projectId` are the canonical deploy identity.
- Windows prebuilt deploy results are not reliable evidence of app correctness when symlink packaging is involved.
