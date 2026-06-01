# _stack legacy mutating prompt migration lane a

- date: `2026-06-01`
- scope: bounded prompt-surface migration that carries the spec-to-diff completion contract into the highest-frequency mutating prompt surfaces
- pattern: `Spec-to-Diff Verification Gate`
- failure mode: `Summary-Truth Drift`

## Files Changed

- `docs/codex-orchestration.md`
- `docs/dispatcher-protocol.md`
- `docs/runbooks/STACK-WORKER-FLOW.md`
- `ops/codex/CodexRunner.Common.ps1`
- `ops/codex/Invoke-CodexRepoTask.ps1`
- `ops/codex/Test-StackOperatorSurface.ps1`
- `ops/stack/StackWorkerArtifacts.ps1`
- `ops/stack/Test-StackWorkerArtifacts.ps1`
- `package.json`
- `queue/README.md`
- `templates/child-task-handoff.md`
- `queue/pending/20260530-233635-stack-vercel-health-first-implementation-worker-a.md`
- `queue/pending/20260530-233636-atlas-local-data-gateway-broader-adoption-worker-b.md`
- `queue/pending/20260601-021500-stack-legacy-mutating-prompt-migration-lane-a.md`
- `receipts/spec-to-diff-verification-gate-localized-patch-2026-05-31.md`
- `receipts/spec-to-diff-gate-operationalization-2026-05-31.md`
- `receipts/stack-vercel-health-first-implementation-worker-packet-1-2026-05-30.md`
- `receipts/stack-vercel-health-first-implementation-worker-proof-and-receipt-packet-2-2026-05-31.md`
- `scripts/vercel-health.mjs`
- `scripts/vercel-health.test.mjs`

## What Changed

- the runner now enforces a temporary spec-to-diff completion artifact whenever a mutating prompt declares explicit acceptance criteria
- shared prompt guidance now requires `Acceptance Criteria`, `Expected Changed Paths`, `Expected Unchanged Paths`, and `Blocked / Skipped Reporting Rules` for governed mutating work
- queue drop guidance and active prompt examples now carry the same contract so new mutating prompt surfaces do not silently stay on the compatibility path
- the previously stranded `_stack vercel-health` worker packet files and receipts are now preserved as intended repo truth
- stale executed queue drops are no longer left in `pending/`; the queue can now distinguish live work from archived task history again

## Prompt Surfaces Migrated Now

- `templates/child-task-handoff.md`
- `queue/README.md`
- `queue/pending/20260601-021500-stack-legacy-mutating-prompt-migration-lane-a.md`
- retained example queue drops under `queue/done/**`
- runner-emitted prompt contract handling inside `Invoke-CodexRepoTask.ps1`

## Deferred Or Residual Surfaces

- prompts that are intentionally non-mutating or exploratory may still omit the mutating-task contract
- legacy mutating prompt surfaces outside the audited `_stack` shared templates and queue examples remain a later adoption lane rather than part of this bounded migration pass

## Verification

- `powershell -NoProfile -ExecutionPolicy Bypass -File .\ops\codex\Test-StackOperatorSurface.ps1`
- `powershell -NoProfile -ExecutionPolicy Bypass -File .\ops\stack\Test-StackWorkerArtifacts.ps1`
- `git diff --check`

## Outcome

- `_stack` dirty state in this lane is legitimate preserved work, not accidental residue
- the queue state is normalized so executed drops are archived instead of posing as still-pending work
- the repo is ready to be admitted as new intended truth once verification is green

## Exact Next Packet

- none inside this bounded lane; return to ATLAS root for validation and lock-refresh admissibility review once owner-side disposition across the other pinned-drift repos is complete
