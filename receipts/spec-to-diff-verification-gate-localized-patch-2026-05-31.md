# _stack spec-to-diff verification gate localized patch

- date: `2026-05-31`
- scope: localized `_stack` worker completion hardening only
- pattern: `Spec-to-Diff Verification Gate`
- failure mode: `Summary-Truth Drift`

## Files Changed

- `templates/child-task-handoff.md`
- `ops/codex/CodexRunner.Common.ps1`
- `ops/codex/Invoke-CodexRepoTask.ps1`
- `ops/codex/Test-StackOperatorSurface.ps1`
- `docs/codex-orchestration.md`
- `docs/runbooks/STACK-WORKER-FLOW.md`
- `receipts/spec-to-diff-verification-gate-localized-patch-2026-05-31.md`
- `../../.github/workflows/atlas-qa-llel.yml`

## What Changed

- worker handoff prompts now expose explicit `Acceptance Criteria`, `Expected Changed Paths`, `Expected Unchanged Paths`, and `Blocked / Skipped Reporting Rules` sections for mutating work
- the shared runner now parses that contract and turns it into a spec-to-diff policy
- mutating prompts with acceptance criteria now require a temporary machine-readable completion artifact at `.codex/spec-to-diff-proof.json`
- the runner now blocks success and commit unless every declared criterion is present in that artifact and every `satisfied` criterion is provable from the final diff
- expected unchanged path violations now fail closed unless the artifact includes an explicit justification
- `_stack` docs now state that `git diff --check` is hygiene only and that screenshot proof is not source-edit proof
- the root `atlas-qa-llel` workflow no longer references the missing `docs/codex/ATLAS-QA-LLEL-PROMPT-PACK.md`

## How The Gate Works

1. A mutating prompt declares individually checkable acceptance criteria plus expected changed and unchanged paths.
2. `Invoke-CodexRepoTask.ps1` appends a spec-to-diff completion contract to the effective Codex prompt.
3. Codex must emit `.codex/spec-to-diff-proof.json` with one entry per criterion and status `satisfied`, `skipped`, `failed`, or `blocked`.
4. The runner copies that artifact into the run log, removes the temporary worktree copy, computes final changed paths, and validates criterion-level proof.
5. A `satisfied` criterion must cite supporting changed paths and literal `diff_evidence` that appears in the final diff or added file content.
6. Missing artifact, missing criterion entries, unsupported evidence, contradictory path claims, blocked/skipped/failed criteria, or unjustified expected-unchanged-path changes all fail closed and block commit.

## Legacy Behavior That Remains

- prompts without explicit acceptance criteria remain on the legacy completion path
- `git diff --check` still runs as whitespace and patch hygiene only
- repo adapter proof gates still operate independently for their own artifact domains
- final summary output remains useful for operator review, but it is no longer the success authority when the spec-to-diff gate is enabled

## Verification

- `powershell -NoProfile -ExecutionPolicy Bypass -File .\ops\codex\Test-StackOperatorSurface.ps1`
  - blocked by pre-existing local environment assumptions before the new proof-gate cases run
  - observed blocker: missing `fawxzzy-mazer` path and failed Mazer deploy identity preflight
- `powershell -NoProfile -ExecutionPolicy Bypass -File .\ops\stack\Test-StackWorkerArtifacts.ps1`
  - blocked by a pre-existing missing artifact under `repos\fawxzzy-lifeline\examples\privileged-execution\capability-profile.json`
- `git diff --check`
  - root worktree reports unrelated pre-existing blank-line-at-EOF findings
  - touched localized patch files pass targeted `git diff --check -- <paths>` aside from line-ending warnings
- focused smoke load of `CodexRunner.Common.ps1` plus parser/spec-to-diff validator path
  - exit code `0`

## Known Limitations

- criterion proof is literal snippet and path based; it proves declared diff evidence, not full semantic equivalence
- the gate activates only when prompts declare explicit acceptance criteria
- broad `_stack` verification remains partially blocked by unrelated local environment drift outside this patch lane
