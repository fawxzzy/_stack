# _stack stack queue-or-registry launch-or-dispatch first implementation worker packet 1

- date: `2026-06-13`
- scope: first admitted `_stack` `stack queue-or-registry launch-or-dispatch` implementation slice only
- guard: `No-completion guard: this packet may admit future implementation of one explicit launch-or-dispatch wrapper input parser, one root-relative ref normalization layer for pending-queue-drop or stack-runner-config or dispatch-inbox-root or dispatch-logs-root refs, one bounded prompt-copy staging write into the admitted repo-local inbox home, one bounded _stack runner start invocation, one bounded wrapper report renderer, and one fail-closed lineage-mismatch or invalid-dispatch-inbox-root or invalid-dispatch-logs-root or prompt-stage-write-failed or worker-start-artifacts-missing handler, but it may not mutate or remove the original pending queue drop, move files into claimed or done queue homes, inspect ambient queue or inbox or historical log state, claim worker completion or verification success or commit success, invoke merge or pause or resume flows, mutate owner-repo surfaces outside the admitted _stack inbox and logs homes, or imply lifecycle advancement, deploy readiness, or publication proof.`

## Files Changed

- `ops/stack/Invoke-QueueOrRegistryLaunchOrDispatch.ps1`
- `scripts/queue-or-registry-launch-or-dispatch.mjs`
- `scripts/queue-or-registry-launch-or-dispatch.test.mjs`
- `ops/codex/Test-StackOperatorSurface.ps1`
- `package.json`
- `README.md`
- `docs/codex-orchestration.md`
- `docs/dispatcher-protocol.md`
- `workspace.manifest.json`
- `receipts/stack-queue-or-registry-launch-or-dispatch-first-implementation-worker-packet-1-2026-06-13.md`

## Commands Run

- `node --test .\scripts\queue-or-registry-launch-or-dispatch.test.mjs`
- `powershell -NoProfile -ExecutionPolicy Bypass -File .\ops\codex\Test-StackOperatorSurface.ps1`
- `pnpm run codex:stack:verify`
- `python ops\stack\generate_lockfile.py`
- `python ops\validation\validate_stack.py --ratchet`

## Result

- first-slice implementation landed as one bounded `_stack` command surface:
  - `stack queue-or-registry launch-or-dispatch`
- the wrapper now accepts only the four admitted explicit refs:
  - pending queue drop
  - stack runner config
  - dispatch inbox root
  - dispatch logs root
- the wrapper now stages only one prompt copy under one admitted `_stack` inbox home and preserves the original pending queue drop
- the wrapper now delegates only to one admitted `_stack` runner start helper:
  - `Invoke-QueueOrRegistryLaunchOrDispatch.ps1`
- the wrapper now proves only one bounded worker-start seam:
  - one `worker.assignment.json`
  - one `worker.status.running.json`
- success reporting is now frozen to the admitted launch-start envelope:
  - normalized refs
  - `staged_prompt_ref`
  - `worker_assignment_ref`
  - `worker_running_status_ref`
  - `stack_lock_digest`
  - one `launch_start_artifact` payload only
- result-class routing is now frozen to:
  - `launch-started`
- `_stack` operator inventory and docs now name the command as an admitted bounded queue-or-registry surface
- root validation finished clean after lock refresh:
  - `critical=0 error=0 warning=0 info=0`

## Proof Cases

- valid explicit pending drop plus bounded inbox/logs home plus one assignment/running pair -> `launch-started`
- pending queue drop outside `repos/_stack/queue/pending/` -> `invalid-pending-queue-drop`
- malformed stack runner config ref -> `invalid-stack-runner-config`
- dispatch inbox root outside `repos/_stack/.codex/inbox/` -> `invalid-dispatch-inbox-root`
- dispatch logs root outside `repos/_stack/.codex/logs/` -> `invalid-dispatch-logs-root`
- contradictory stack lock digest or governed lineage -> `lineage-mismatch`
- bounded staging failure -> `prompt-stage-write-failed`
- bounded runner start failure before usable worker-start output -> `launch-start-failed`
- missing emitted worker-start artifacts -> `worker-start-artifacts-missing`
- malformed emitted helper output -> `malformed-worker-start-output`

## Verification Notes

- `Test-StackOperatorSurface.ps1` passed
- `pnpm run codex:stack:verify` passed
- the new node proof suite passed for the admitted first slice
- root validation remained clean after the lock refresh

## Stop Conditions Not Triggered

- no original pending queue drop mutation was added
- no `claimed/` or `done/` queue movement was added
- no worker completion, verification success, merge, pause, or resume flow was added
- no owner-repo mutation was added outside the admitted `_stack` inbox and logs homes
- no lifecycle-advancement, deploy-readiness, or publication claim was introduced
- no widening beyond the admitted first slice was required

## Exact Next Packet

- `_stack stack queue-or-registry launch-or-dispatch first-implementation worker proof-and-receipt packet 2`
