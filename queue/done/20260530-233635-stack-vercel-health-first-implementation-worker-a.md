Task Class: operator-workflow
Target: _stack
Working Directory: repos/_stack
Allowed Edit Surface:
- repos/_stack/**
Stack Lock Digest: 8B609C25FFF8FA510308BBDE6353C907BC3137828F29D972A2D0F0CE8877170A

Objective:
Implement the already-admitted first `_stack vercel-health` slice only.

Context:
- `_stack vercel-health` is implementation-ready from the ATLAS control-plane standpoint.
- The worker must inherit the frozen pass-9 through pass-16 contract chain.
- `_stack` is the operator layer for shared workflow commands and should follow existing repo script and test patterns.

Mandatory Inherited Contract:
- pass 9: command purpose and health classes
- pass 10: admitted evidence classes and freshness rules
- pass 11: report contract and contradiction routing
- pass 12: implementation-admission boundary and no-execution guard
- pass 13: fixture/static-input provenance and truth limits
- pass 14: first-slice scope and proof matrix
- pass 15: worker handoff contract
- pass 16: implementation-readiness closeout and worker-routing rule

Implementation Scope:
- awareness-only command surface
- read-only admitted-evidence loading
- local classification using frozen rules
- frozen report-contract rendering
- fail-closed unsupported-input handling
- fixture/static-input proof harness

Likely Files:
- repos/_stack/package.json
- repos/_stack/scripts/vercel-health.mjs
- repos/_stack/scripts/vercel-health.test.mjs
- repos/_stack/scripts/command-runner.mjs only if strictly required
- repos/_stack/receipts/FIRST-IMPLEMENTATION-WORKER-PACKET-1-2026-05-30.md or equivalent repo-local receipt

Constraints:
- Preserve the local-first workflow model.
- Do not edit files outside the allowed surface.
- Prefer existing `package.json` scripts over ad hoc commands.
- Do not create opportunistic repo changes.
- Do not execute Vercel operations, mutate any surface, inspect protected live state, or imply deploy/runtime proof.
- Do not widen beyond the admitted first slice.
- Do not change health semantics, report contract, or admitted evidence classes.

No-execution Guard:
No-execution guard: this packet may implement awareness-only read, classification, and report rendering over already-admitted evidence classes, but it may not execute Vercel operations, mutate any surface, inspect protected live state, or imply deploy/runtime proof.

Stop-And-Return Triggers:
- protected access becomes necessary
- live verification becomes necessary
- mutation, deploy, repair, rollback, promote, or delete behavior becomes necessary
- widening beyond the admitted first slice becomes necessary
- owner proof, runtime truth, or publication truth would need to be inferred
- any new evidence class would need to be admitted
- any report-contract or health-semantics change would be required

Acceptance Criteria:
- [command-surface] Land the admitted first `_stack vercel-health` implementation surface inside the allowed repo-local files only.
- [proof-harness] Add repo-local proof coverage for the frozen awareness-only report and fail-closed unsupported-input behavior.
- [bounded-scope] Keep the packet inside the admitted first slice without widening health semantics, admitted evidence classes, or execution authority.

Expected Changed Paths:
- repos/_stack/package.json
- repos/_stack/scripts/vercel-health.mjs
- repos/_stack/scripts/vercel-health.test.mjs
- repos/_stack/scripts/command-runner.mjs
- repos/_stack/receipts/**

Expected Unchanged Paths:
- repos/_stack/docs/**
- repos/_stack/ops/**

Blocked / Skipped Reporting Rules:
- Do not mark a criterion as satisfied unless the final diff proves it.
- If the first slice cannot land without widening scope or execution authority, mark the affected criterion as blocked, skipped, or failed and explain why.
- If any expected unchanged path must change, report it explicitly and justify it instead of summarizing the packet as clean success.

Verification:
- use the repo's existing `node --test` style
- run the smallest honest repo-local verification chain
- likely include `pnpm run codex:stack:verify` only if the slice integrates cleanly enough for the full shared verification surface
- otherwise run the narrowest new test command plus any existing command it depends on and report why

Deliver Back:
- summary of changes
- files changed
- exact commands run
- exact proof cases passed or failed
- whether first-slice implementation landed cleanly
- exact blocker if not
- criterion-by-criterion completion status
- one exact next packet only
