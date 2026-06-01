# _stack spec-to-diff gate operationalization

- date: `2026-05-31`
- scope: localized `_stack` operational validation and blocker cleanup for the spec-to-diff completion gate
- rule: `mutating Codex tasks are not considered governed unless they declare acceptance criteria`

## Files Changed

- `docs/codex-orchestration.md`
- `docs/runbooks/STACK-WORKER-FLOW.md`
- `ops/codex/CodexRunner.Common.ps1`
- `ops/codex/Invoke-CodexRepoTask.ps1`
- `ops/codex/Test-StackOperatorSurface.ps1`
- `ops/stack/StackWorkerArtifacts.ps1`
- `ops/stack/Test-StackWorkerArtifacts.ps1`
- `templates/child-task-handoff.md`
- `receipts/spec-to-diff-gate-operationalization-2026-05-31.md`

## What Changed

- `_stack` docs now state the governance rule that mutating Codex work is not governed unless the prompt declares acceptance criteria
- `_stack` verification now skips workspace-specific Mazer and Lifeline owner-repo checks when those sibling repos or built artifacts are absent, instead of failing the whole operator surface on workspace shape alone
- the runner now tolerates minimal adapters and prompt-only governed context inputs without crashing on missing optional properties
- the spec-to-diff unchanged-path validator no longer crashes when no justification candidate exists

## Operational Proof

Synthetic success case through `Invoke-CodexRepoTask.ps1`:

- result: `success`
- runner exit code: `0`
- `specToDiff.validationPassed = true`
- `specToDiff.artifactProvided = true`
- `specToDiff.artifactRemoved = true`
- commit created: yes

Synthetic failure case through `Invoke-CodexRepoTask.ps1`:

- result: `spec_to_diff_failed`
- runner exit code: `17`
- `specToDiff.validationPassed = false`
- `specToDiff.artifactProvided = true`
- `specToDiff.artifactRemoved = true`
- commit created: no
- blocking reason: `Criterion 'runner-gate' evidence 'Missing success marker.' was not found in the final diff or file content for its declared paths.`

This failure case intentionally emitted a summary that implied completion while the proof artifact cited unsupported diff evidence. The gate blocked completion before commit.

## Verification

- `powershell -NoProfile -ExecutionPolicy Bypass -File .\ops\codex\Test-StackOperatorSurface.ps1`
  - pass
- `powershell -NoProfile -ExecutionPolicy Bypass -File .\ops\stack\Test-StackWorkerArtifacts.ps1`
  - pass
- `git diff --check`
  - pass for the `_stack` worktree
  - line-ending warnings only

## Remaining Governance Note

- legacy mutating prompts still remain on the compatibility path until they are migrated onto the acceptance-criteria contract
- prompt migration remains a backlog lane, not part of this localized operationalization pass
