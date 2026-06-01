Task Class: repo-local
Target: atlas
Working Directory: .
Allowed Edit Surface:
- docs/ops/**
Stack Lock Digest: 8B609C25FFF8FA510308BBDE6353C907BC3137828F29D972A2D0F0CE8877170A

Objective:
Run one root-bounded, docs-only Local Data Gateway packet that selects the next honest broader-adoption candidate beyond the already-proven no-send set.

Primary File:
- docs/ops/LOCAL-DATA-GATEWAY-BROADER-ADOPTION-CANDIDATE-SELECTION-AND-PACKET-ADMISSION-PASS-2-2026-05-30.md

Context:
- This is the independent Wave 1 ATLAS-root lane.
- It must not overlap with `_stack` repo implementation work.
- It must stay below shared restart-spine refresh so the dispatcher can reconcile it later in one batch.

Constraints:
- Preserve the local-first workflow model.
- Do not edit files outside the allowed surface.
- Do not touch `docs/atlas-book/**` in this wave.
- Do not touch `repos/_stack/**`.
- Evaluate only root-visible, receipt-backed adoption candidates.
- Do not reopen send-capable behavior.
- Do not reopen owner-side implementation.
- Do not ratchet markers from wording alone.

Acceptance Criteria:
- [candidate-audit] Update the primary file to name the exact broader-adoption candidate families considered from root-visible evidence.
- [decision] Update the primary file to name one exact winner or hold decision and explain why it is admit-now, later, or blocked.
- [durability-call] Update the primary file to state whether the recommendation is durable or inference-backed.

Expected Changed Paths:
- docs/ops/**

Expected Unchanged Paths:
- docs/atlas-book/**
- repos/_stack/**

Blocked / Skipped Reporting Rules:
- Do not mark a criterion as satisfied unless the final diff proves it.
- If the packet cannot honestly name a winner, mark the decision criterion as blocked, skipped, or failed and explain why.
- If any path outside `docs/ops/**` would need to change, report that as a blocker instead of widening the packet silently.

Required Outcome:
- exact candidate families considered
- exact winner, if any
- exact reason it is admit-now versus later or blocked
- exact next packet only
- whether the recommendation is durable or inference-backed

Verification:
- run `python .\\ops\\validation\\validate_stack.py`
- report exact validation result

Deliver Back:
- summary of changes
- files changed
- exact commands run
- exact candidate chosen or hold decision
- validation result
- criterion-by-criterion completion status
- one exact next packet only
