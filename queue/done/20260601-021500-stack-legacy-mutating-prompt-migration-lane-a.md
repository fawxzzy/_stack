Task Class: repo-local
Target: stack
Working Directory: .
Allowed Edit Surface:
- templates/**
- docs/**
- queue/**
Stack Lock Digest: 8B609C25FFF8FA510308BBDE6353C907BC3137828F29D972A2D0F0CE8877170A

Objective:
Run one bounded `_stack` migration lane that converts the highest-frequency mutating prompt surfaces onto the acceptance-criteria contract so the new spec-to-diff gate compounds beyond the initial runner implementation.

Primary File:
- templates/child-task-handoff.md

Context:
- The `_stack` spec-to-diff gate and Summary-Truth Drift mitigation are already proven and closed at the mechanism level.
- The remaining open risk is legacy mutating prompts silently falling back to the compatibility path.
- This lane is adoption work, not runner redesign.

Constraints:
- Do not reopen the spec-to-diff runner architecture.
- Do not widen into ATLAS QA/LLEL redesign.
- Do not touch unrelated repos.
- Prefer converting shared prompt templates and high-frequency mutating prompt surfaces first.
- Preserve backward compatibility where a prompt is intentionally non-mutating or exploratory.
- New mutating prompt surfaces must not be introduced without the acceptance-criteria contract.

Acceptance Criteria:
- [guidance] Update the shared `_stack` prompt-authoring guidance so mutating queue drops and child-task handoffs require the acceptance-criteria contract.
- [live-prompts] Convert the highest-frequency live mutating prompt examples inside `_stack` onto the acceptance-criteria contract.
- [residual-risk] Leave an explicit record of which mutating prompt surfaces were migrated now versus intentionally deferred.

Expected Changed Paths:
- templates/**
- docs/**
- queue/**

Expected Unchanged Paths:
- ops/**
- receipts/**

Blocked / Skipped Reporting Rules:
- Do not mark a criterion as satisfied unless the final diff proves it.
- If a prompt surface is intentionally left on the legacy path, mark that in the deliver-back as deferred rather than implying universal governed coverage.
- If any non-listed surface would need to change, report that as blocked instead of widening the packet silently.

Required Outcome:
- exact mutating prompt surfaces audited
- exact surfaces converted now
- exact legacy surfaces intentionally left for later
- exact rule added or reinforced for future mutating prompt creation
- exact residual adoption risk after this packet

Verification:
- run `powershell -NoProfile -ExecutionPolicy Bypass -File .\\ops\\codex\\Test-StackOperatorSurface.ps1`
- run `git diff --check`
- report exact verification result

Deliver Back:
- summary of changes
- files changed
- verification result
- migrated surfaces
- deferred surfaces
- criterion-by-criterion completion status
- one exact next packet only
