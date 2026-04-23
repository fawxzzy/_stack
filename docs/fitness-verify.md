# Fitness Verify

Use this note when the change touches Fitness UI behavior, especially bottom-action intent consistency.

## Ownership

- `_stack` owns workflow entrypoints, operator docs, tasks, and receipts.
- `repos/fawxzzy-fitness` owns Fitness application code, UI contracts, tests, lint, and build verification.
- Do not move Fitness implementation logic into `_stack`. `_stack` should only point to the correct repo-local verify surface.

## Where to run what

Run shared workflow commands from `_stack`:

```bash
cd repos/_stack
pnpm run fitness:doctor
pnpm run fitness:verify
pnpm run fitness:verify:clean
pnpm run fitness:deploy:preflight
```

`fitness:verify` is the standard workflow entrypoint and currently delegates to the Fitness repo's strict verify command. Use `fitness:verify:clean` when you need a fresh `.next` state before verifying or deploying.
`fitness:deploy:preflight` is the required production-link guard. It validates immutable Vercel `teamId` and `projectId` first, then checks the current slug/name for rename drift.

Run code/test/build checks from the Fitness repo root:

```bash
cd repos/fawxzzy-fitness
npm run verify:strict
```

Use repo-local commands in the Fitness repo when you need to isolate a specific failure or validate an in-progress UI change:

```bash
cd repos/fawxzzy-fitness
npm run lint
npm run build
```

Optional focused checks, when the change touches a covered area:

```bash
cd repos/fawxzzy-fitness
npm run test:session-set-count
npm run test:mobile-regression-fixtures
```

## Bottom-action intent checklist

1. Start the shared workflow verify path from `_stack` so operator flow stays consistent.
2. Switch to `repos/fawxzzy-fitness` for repo-local validation and run `npm run verify:strict` or the narrower repo-local checks you need.
3. Before any production deploy, run `pnpm run fitness:deploy:preflight` from `_stack`.
4. If the preflight reports rename drift, update the checked-in `_stack/config/fitness-deploy.identity.json` slug/name to the connector-confirmed current values instead of relinking to a different project.
5. If the preflight reports a team ID mismatch, the repo is linked to the wrong Vercel account/team.
6. If the preflight reports a project ID mismatch under the correct team ID, the repo is linked to the wrong Vercel project.
7. Use `docs/ops/fitness-vercel-deploy-recovery.md` for the full recovery lane, including connector-first inspection and the Windows prebuilt caveat.
8. Confirm the screen uses the shell-owned bottom action surface correctly:
   - only screen shells own `BottomActionsProvider` / `BottomActionsSlot`
   - feature components publish actions instead of mounting their own dock surface
9. Confirm the button uses the canonical intent mapping in `src/components/layout/bottomActionIntents.ts`.
10. Confirm rendered bottom actions expose the expected `data-bottom-action-intent` value through shared dock components such as `BottomDockButton` / `BottomDockLink`.
11. In local dev, compare the changed screen against the deterministic contract route at `/dev/ui-contract` to check repeated button families and dock treatment.
12. If the change affects dock semantics, verify the chosen intent still matches the user action:
   - `positive` for forward/commit actions
   - `info` for neutral secondary actions
   - `danger` for destructive actions
   - `toggleInactive` / `toggleActive` for stateful toggle behavior

## Decision rule

- If you are validating workflow entrypoints, stay in `_stack`.
- If a failure looks like stale local Next build state, use `pnpm run fitness:verify:clean` from `_stack` before chasing application code.
- If you are validating Fitness behavior, contract usage, lint, tests, or build output, run from `repos/fawxzzy-fitness`.
