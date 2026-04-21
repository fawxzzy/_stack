# _stack Orchestration Adoption

This document is the repo-owned adoption note and contract map for `_stack` orchestration.

`_stack` is the owner of stack orchestration artifacts and operator flow inside this repo. It is not the owner of shared workflow-pack reuse, privileged-execution lineage, or Fitness telemetry/receipt semantics.

## Status

Current status for this slice is `owner freeze landed`.

That label is intentionally narrow:

- `_stack` can now adopt the frozen owner contracts as a consumer.
- This is not repo-wide certification for Playbook.
- `pnpm verify:local` in Playbook is still blocked by unrelated lint debt.
- the agent command path is still workspace-blocked by the current Windows symlink issue.

Those constraints do not block `_stack` adoption. They do block any broader claim that Playbook is fully certified end to end.

## Consumer Rule

`_stack` consumes owner contracts. It does not copy them, restate them as new local truth, or widen their ownership boundary.

Required posture:

- consume the Playbook workflow-pack bundle as a consumer, not a copy
- consume Lifeline privileged-execution lineage for execution request, approval, and receipt truth
- reference the Fitness integration contract when execution or observation touches app telemetry channels, bounded actions, or receipts
- keep `_stack` docs and tests explicit about which repo owns which contract

## Contract Map

| Concern | `_stack` surface | Owner truth | `_stack` adoption rule |
| --- | --- | --- | --- |
| Workflow-pack reuse | `README.md`, `docs/runbooks/STACK-WORKER-FLOW.md`, operator verify flow | `../fawxzzy-playbook/docs/contracts/WORKFLOW_PACK_REUSE_CONTRACT.md`, `../fawxzzy-playbook/docs/CONSUMER_INTEGRATION_CONTRACT.md` | Discover verification, promotion, registry, and consumer rules from Playbook owner docs and canonical artifacts. `_stack` must not publish a second workflow-pack spec. |
| Worker orchestration | `ops/stack/StackWorkerArtifacts.ps1`, `docs/runbooks/STACK-WORKER-FLOW.md` | `_stack` owner truth in this repo | `_stack` owns assignment, status, merge-request, merger-assignment, and resume-context orchestration artifacts. Those artifacts must preserve external lineage keys when governed execution is involved. |
| Privileged execution lineage | `Invoke-StackLifelineExecution` in `ops/stack/StackWorkerArtifacts.ps1` | `../fawxzzy-lifeline/docs/contracts/privileged-execution-contract.md` | `_stack` must use Lifeline contract versions and lineage fields for `atlas.capability.profile.v1`, `atlas.privileged-action.request.v1`, `atlas.approval.receipt.v1`, and `atlas.privileged-action.receipt.v1`. `_stack` may bridge and index them; it does not own or reshape them. |
| Execution observations | `docs/runbooks/STACK-WORKER-FLOW.md`, worker status bridge artifacts | Lifeline execution lineage plus stack-level `atlas.observation.v1` usage described in the runbook | Lifeline emits execution facts from the execution chain. `_stack` emits orchestration facts such as `assignment_created`, `heartbeat`, `completed`, `merge_requested`, `paused`, `merger_assigned`, and `resume_ready`. `_stack` must not mint alternate execution-side status families. |
| Fitness telemetry and receipts | execution requests, observation envelopes, and any downstream worker proof that names Fitness channels/actions/receipts | `../fawxzzy-fitness/src/lib/ecosystem/fitness-integration-contract.ts` | When a governed worker flow touches Fitness telemetry or receipts, `_stack` must reference the Fitness contract channels, action types, and receipt types as external truth. `_stack` may point to them in artifacts and docs, but it must not rename or reinterpret them into a local app dialect. |
| Merge and resume | `Invoke-StackSupervisorConsumer`, `docs/runbooks/STACK-WORKER-FLOW.md` | `_stack` owner truth for orchestration; Lifeline owner truth for any execution receipts carried through the flow | Pause, merge, and resume stay `_stack`-owned, but any governed merge or resume artifact must preserve the same `worker_id`, `assignment_id`, `stack_lock_digest`, `tool_id`, `extension_id`, and `registry_digest` that tie back to Lifeline lineage and Playbook-governed surfaces. |

## Adoption Boundaries

What `_stack` is allowed to add:

- consumer notes that point at owner contracts
- compatibility checks that fail when owner paths drift or disappear
- deterministic bridge artifacts that preserve upstream identifiers and refs

What `_stack` is not allowed to add:

- a copied local workflow-pack schema inventory
- a replacement privileged-execution receipt schema
- Fitness-specific channel or receipt naming invented in `_stack`
- root-level prose that duplicates owner-repo truth

## Verification Rule

`pnpm run codex:stack:verify` must prove this adoption slice by checking both:

- the worker artifact and Lifeline bridge behavior
- the presence and wording of this contract map plus the upstream owner paths it depends on
