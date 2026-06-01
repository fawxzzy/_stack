# Stack Worker Flow

For owner boundaries and the consumer contract map for Playbook, Lifeline, and Fitness, see [`../STACK-ORCHESTRATION-ADOPTION.md`](../STACK-ORCHESTRATION-ADOPTION.md).

`_stack` is the first executor of the ATLAS worker contracts. Every spawned job stamps the current root `stack.lock.yaml` digest into its worker artifacts, builds a deterministic worker context pack, and keeps the handoff surface explicit.

This runbook is `_stack` owner truth for orchestration mechanics. It consumes the Playbook workflow-pack bundle as a consumer, bridges execution through Lifeline owner contracts, and references the Fitness integration contract when governed execution touches telemetry channels or receipt types.

The closed loop is:

1. assignment
2. deterministic worker context pack
3. execution request + approval
4. Lifeline execution + receipt
5. supervisor conflict detection
6. pause / merge / resume artifacts

## Artifact Set

- `worker.assignment.json`
- worker context under `runtime/cortex/context/<assignment_id>.json`
- `worker.status.running.json`
- `worker.status.completed.json`
- `worker.status.execution.<receipt_id>.json` when a worker action is executed through Lifeline
- `worker.merge-request.json` when pause/merge is required

The runner writes these artifacts into the repo-local Codex log directory for the job run.

## Assignment

The assignment artifact declares the worker scope before execution starts.

Required fields:

- `assignment_id`
- `worker_id`
- `task_id`
- `stack_lock_digest`
- `allowed_globs`
- `forbidden_globs`
- `input_handoff_refs`
- `expected_outputs`

Governed fields when the root flow is using a registered surface:

- `tool_id`
- `extension_id` when the surface is extension-backed
- `registry_digest`

Rules:

- the assignment must use the current root lock digest
- input handoff refs should point at the prompt, worker context artifact, or paused handoff artifacts, not ad hoc transcripts
- forbidden globs are hard exclusions
- `_stack` preserves governed fields when the root flow provides them; it does not mint private public tool ids for generic local tasks

## Worker Context

Each worker assignment now gets a deterministic Cortex context artifact before execution starts.

Rules:

- the context artifact is built from the promoted knowledge query plane
- `_stack` passes the context artifact path into worker handoff refs and prompt scaffolding
- `metadata_only` archives stay metadata-only inside the context pack
- `derived_only` archives may contribute derived summary, topic map, and evidence refs
- raw evidence is never hydrated into the worker context artifact

## Execution Bridge

Execution stays explicit and receipt-backed. `_stack` does not hold ambient privilege and does not execute worker actions directly once the request reaches the execution phase.

Rules:

- `_stack` passes read-only and dry-run worker actions to Lifeline through the worker assignment + status refs, a capability profile ref, a privileged-action request artifact, and an approval receipt artifact
- the request, approval, and worker assignment must all match the same `worker_id`, `assignment_id`, `stack_lock_digest`, and governed surface identity when present
- `_stack` only bridges `read_only_scan` and dry-run `scoped_write` in this phase
- Lifeline emits the privileged-action receipt under `runtime/lifeline/worker-execution/<assignment_id>/`
- `_stack` writes the resulting receipt ref back into a new worker status artifact instead of inferring execution from terminal logs

Bridge outputs:

- privileged-action receipt ref
- `worker.status.execution.<receipt_id>.json`
- `worker.execution.<receipt_id>.json` bridge record

Lifeline is also responsible for publishing the execution-side root observations for governed flows:

- `execution_requested`
- `execution_approved`
- `execution_rejected`
- `execution_expired`
- `execution_completed`

Those observations must be rooted at the stack-level `atlas.observation.v1` contract. Lifeline does not become a second state store; it emits facts and root builds current state from them.

## Status

Status is the observation surface for the worker.

Required fields:

- `worker_id`
- `assignment_id`
- `state`
- `heartbeat_at`
- `touched_ranges`
- `output_refs`
- `blocked_reason`

Governed fields when present:

- `tool_id`
- `extension_id`
- `registry_digest`

Each touched range must include:

- `repo_path`
- `repo_commit`
- `file_digest_before`
- `path`
- `start_line`
- `end_line`
- `op`

Rules:

- line ranges are the observation surface
- commit and pre-edit digest anchor the range meaning
- completion is the terminal `state = completed` status artifact
- for mutating prompts with acceptance criteria, completion also requires criterion-level proof against the final repo diff before `_stack` may emit `state = completed`

## Spec-To-Diff Completion Gate

Pattern: `Spec-to-Diff Verification Gate`

Mutating worker prompts may declare explicit acceptance criteria plus expected changed and unchanged paths. When they do, the worker must emit a temporary spec-to-diff completion artifact before `_stack` can mark the run completed.

Gate rules:

- one artifact entry per acceptance criterion
- each `satisfied` criterion must cite supporting changed paths and literal diff evidence
- changed-path presence alone is not proof
- summary text is not proof
- `git diff --check` is hygiene only
- visual diffs are screenshot proof, not source-edit proof
- blocked, skipped, and failed criteria keep the worker out of the success path
- expected unchanged paths must remain unchanged unless the completion artifact includes an explicit justification
- mutating Codex tasks are not considered governed unless they declare acceptance criteria
- legacy mutating prompts stay on the compatibility path until they are migrated onto the acceptance-criteria contract

Failure Mode: `Summary-Truth Drift`

The failure mode occurs when a worker summary says the requested change is complete but the repository diff does not prove that every requested edit actually landed.

## Pause / Resume / Merge

Pause and merge stay inside the existing ATLAS handoff flow.

Flow:

1. a worker status is written after execution
2. if the worker has a governed execution request, `_stack` calls Lifeline and records the resulting receipt in a new worker status artifact
3. root Cortex reads worker statuses and emits a deterministic merge-request artifact on overlap or drift
4. `_stack` consumes the merge-request artifact and writes paused worker statuses
5. `_stack` emits one merger worker assignment plus a merge prompt from paused handoff refs only
6. `_stack` emits per-worker resume-context artifacts that point at the reserved merged handoff ref
7. paused workers resume only from the paused handoff path and merged handoff output, never raw transcript history

Merge-request required fields:

- `merge_request_id`
- `stack_lock_digest`
- `conflicting_workers`
- `overlaps`
- `paused_handoff_refs`
- `merge_worker_handoff`

Governed fields when present:

- top-level `tool_id`
- top-level `extension_id`
- top-level `registry_digest`
- matching `merge_worker_handoff.tool_id`
- matching `merge_worker_handoff.extension_id`
- matching `merge_worker_handoff.registry_digest`

Consumer outputs:

- paused worker status artifacts
- merger worker assignment
- merger prompt artifact
- resume-context artifacts
- merge completion artifact

The pause, merge, and resume artifacts preserve the same governed surface identity end to end so Cortex, `_stack`, Lifeline, and root status are naming the same public surface.

## Required Observations

`_stack` and Lifeline together must close the governed observation chain. A flow is not complete because logs look complete; it is complete only when the required artifacts and observations exist and agree.

| Owner | Observation | Primary source artifact |
| --- | --- | --- |
| `_stack` | `assignment_created` | `worker.assignment.json` |
| `_stack` | `heartbeat` | `worker.status.running.json` |
| Lifeline | `execution_requested` | `privileged-action.request.json` |
| Lifeline | `execution_approved` / `execution_rejected` / `execution_expired` | `approval.receipt.json` |
| Lifeline | `execution_completed` | `runtime/lifeline/worker-execution/<assignment_id>/receipt.json` |
| `_stack` | `completed` | `worker.status.completed.json` |
| `_stack` | `merge_requested` | `worker.merge-request.json` |
| `_stack` | `paused` | `worker.status.paused.<merge_request_id>.json` |
| `_stack` | `merger_assigned` | `worker.assignment.merge.json` |
| `_stack` | `resume_ready` | `resume-context.<worker_id>.json` or merge completion when no per-worker resume context exists |
| ATLAS root | `resume_requested` | `runtime/atlas/sessions/<session_id>/artifacts/resume.request.json` |
| ATLAS root | `resume_dispatched` | `runtime/atlas/sessions/<session_id>/artifacts/resume.dispatch.json` |
| ATLAS root | `resume_completed` / `resume_failed` | resumed completed status or resumed run manifest |

Every emitted governed observation must carry:

- `session_id`
- `worker_id` when applicable
- `assignment_id` when applicable
- `stack_lock_digest`
- `tool_id`
- `extension_id` when applicable
- `registry_digest`
- `automation_level`
- `source_artifact_refs`

Owner boundary:

- `_stack` emits orchestration facts.
- Lifeline emits execution facts.
- ATLAS root emits resume transition facts.
- root Cortex consumes those facts and builds current state in the world model.

No-dark-state rule:

- completed governed flows must have the full required observation set
- merge and resume flows must emit their pause / merge / resume observations before the flow can be considered closed
- root-owned resume must reuse the existing `_stack` flow rather than minting a second worker orchestration path
- root validation and Playbook verify fail when required observations or closure evidence are missing

## Touched Range Semantics

`repo_commit + file_digest_before + path + start_line/end_line + op` are the observation surface for collision detection. `stack_lock_digest` binds the observation to the exact working set.

For deletions, the range should describe the pre-edit file span. For edits and additions, the range should describe the resulting lines in the committed file.

## Review Path

Use `pnpm run codex:stack:verify` to check the operator surface and worker-artifact helpers together.
