# Lifeline privileged execution contract

This document is the canonical owner-repo contract path for Lifeline privileged execution lineage.

Atlas may reference these contracts as platform doctrine, but Lifeline owns the execution, capability, approval, and receipt semantics documented here.

## Ownership split

- Atlas owns architecture rationale, UAPI framing, and boundary doctrine.
- Lifeline owns capability, request, approval, and receipt execution contracts.
- Playbook may govern approval policy, but it does not own the Lifeline receipt shape.
- `_stack` may originate workflow context and `source_refs`, but it does not own the Lifeline execution schema.

## Canonical lineage

The lineage is strictly ordered:

1. capability profile
2. privileged-action request
3. approval receipt
4. privileged-action receipt

Each later artifact must preserve the identifiers needed to reconstruct the chain.

## Contract register

| Contract | Version | Owner | Purpose | Canonical implementation | Canonical examples |
| --- | --- | --- | --- | --- | --- |
| `atlas.capability.profile.v1` | v1 | Lifeline execution surface | grants bounded filesystem, process, package, network, and budget scope | `src/core/privileged-execution.ts` | `examples/privileged-execution/capability-profile.json`, `examples/privileged-execution/capability-profile.scoped-write-dry-run.json` |
| `atlas.privileged-action.request.v1` | v1 | Lifeline execution surface | declares the requested bounded operation and requested capability scope | `src/core/privileged-execution.ts` | `examples/privileged-execution/read-only-scan.request.json`, `examples/privileged-execution/dry-run-command.request.json` |
| `atlas.approval.receipt.v1` | v1 | Lifeline execution surface; approval policy may be supplied by Playbook | records approval status and granted scope for a request | `src/core/privileged-execution.ts` | `examples/privileged-execution/read-only-scan.approval.json`, `examples/privileged-execution/dry-run-command.approval.json`, `examples/privileged-execution/dry-run-command.rejected.approval.json`, `examples/privileged-execution/dry-run-command.expired.approval.json` |
| `atlas.privileged-action.receipt.v1` | v1 | Lifeline execution surface | records the actual execution attempt and lineage trail | `src/core/privileged-execution.ts` | produced by `lifeline execute` and receipt repair flows |

## Required lineage keys

The following keys are the canonical lineage bridge and must stay explicit across the chain:

- `request_id`
- `approval_receipt_id`
- `capability_profile_id`
- `worker_id`
- `assignment_id`
- `stack_lock_digest`
- `tool_id`
- `extension_id`
- `registry_digest`
- `automation_level`
- `source_refs`
- `failure.category` and `failure.first_remediation_step` on blocked or failed receipts

## Status semantics

These are the only frozen status layers in this pass:

- approval status: `approved`, `rejected`, `expired`
- execution result: `succeeded`, `failed`, `blocked`

Separate top-level shared contracts such as `execution_rejected` and `execution_expired` are not frozen here.
Those remain parked until owner-repo evidence is stronger.

## Boundary rules

- A request may describe intent, but it does not authorize execution on its own.
- An approval receipt may authorize or deny the request, but it does not replace the final execution receipt.
- A privileged-action receipt must record what actually happened, including blocked attempts.
- Rejected and expired approvals remain first-class approval outcomes, not independent shared event families.
- `source_refs` may point to `_stack` artifacts, but Lifeline echoes them without redefining their upstream meaning.
- Path-like receipt refs emitted by Lifeline are normalized to forward slashes before write so Windows and POSIX receipts stay diffable, while upstream `source_refs` remain unchanged.

## Canonical reader guidance

- Use this document for contract lineage and field ownership.
- Use [`../privileged-execution.md`](../privileged-execution.md) for operator workflow and command usage.
- Use `src/core/privileged-execution.ts` for exact field validation and repair behavior.
