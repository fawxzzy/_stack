# _stack stack queue-or-registry claim-state movement first implementation worker packet 1

- date: `2026-06-13`
- scope: first admitted `_stack` `stack queue-or-registry claim-state movement` implementation slice only
- guard: `No-completion guard: this packet may admit future implementation of one explicit claim-state-movement wrapper input parser, one root-relative ref normalization layer for pending-queue-drop or worker-assignment or worker-running-status or claimed-queue-root refs, one bounded pending-to-claimed move into the admitted claimed queue home, one bounded wrapper report renderer, and one fail-closed lineage-mismatch or active-worker-mismatch or invalid-claimed-queue-root or claim-move-failed or malformed-claim-output handler, but it may not inspect ambient queue or historical worker state, move files into done queue homes, claim worker completion or verification success or commit success, invoke merge or pause or resume flows, mutate owner-repo surfaces outside the admitted claimed queue home, or imply lifecycle advancement, deploy readiness, or publication proof.`

## Files Changed

- `scripts/queue-or-registry-claim-state-movement.mjs`
- `scripts/queue-or-registry-claim-state-movement.test.mjs`
- `ops/codex/Test-StackOperatorSurface.ps1`
- `package.json`
- `workspace.manifest.json`
- `README.md`
- `docs/codex-orchestration.md`
- `receipts/stack-queue-or-registry-claim-state-movement-first-implementation-worker-packet-1-2026-06-13.md`

## Commands Run

- `node --test .\scripts\queue-or-registry-claim-state-movement.test.mjs`
- `powershell -NoProfile -ExecutionPolicy Bypass -File .\ops\codex\Test-StackOperatorSurface.ps1`
- `pnpm run codex:stack:verify`
- `git diff --check`
- `python ops\stack\generate_lockfile.py`
- `python ops\validation\validate_stack.py --ratchet`

## Result

- first-slice implementation landed as one bounded `_stack` command surface:
  - `stack queue-or-registry claim-state movement`
- the wrapper now accepts only the four admitted explicit refs:
  - pending queue drop
  - worker assignment
  - worker running status
  - claimed queue root
- the wrapper now validates one explicit active-worker proof pair and one admitted claimed queue home only
- the wrapper now moves only one explicit pending queue drop from:
  - `repos/_stack/queue/pending/`
  into:
  - `repos/_stack/queue/claimed/`
- success reporting is now frozen to the admitted claim-state envelope:
  - normalized refs
  - `claimed_queue_drop_ref`
  - `stack_lock_digest`
  - one `claim_movement_artifact` payload only
- result-class routing is now frozen to:
  - `claim-moved`
- `_stack` operator inventory and docs now name the command as an admitted bounded queue-or-registry surface
- root validation finished clean after lock refresh:
  - `critical=0 error=0 warning=0 info=0`

## Proof Cases

- valid explicit pending drop plus one valid active-worker proof pair plus one valid claimed queue home -> `claim-moved`
- pending queue drop outside `repos/_stack/queue/pending/` -> `invalid-pending-queue-drop`
- malformed worker assignment -> `invalid-worker-assignment`
- malformed or non-running worker status -> `invalid-worker-running-status`
- claimed queue root outside `repos/_stack/queue/claimed/` -> `invalid-claimed-queue-root`
- contradictory lock digest or governed lineage -> `lineage-mismatch`
- contradictory worker identity between assignment and running status -> `active-worker-mismatch`
- unusable bounded claimed target -> `claim-move-failed`
- malformed emitted claim output truth -> `malformed-claim-output`
- bounded text rendering success path -> pass

## Verification Notes

- `Test-StackOperatorSurface.ps1` passed
- `pnpm run codex:stack:verify` passed
- the new node proof suite passed for the admitted first slice
- root validation required warning-first hygiene before this packet:
  - remove generated `repos/DiscordOS/node_modules`
  - refresh `stack.lock.yaml` before resuming owner-side implementation

## Stop Conditions Not Triggered

- no queue history or worker history scans were added
- no `queue/done/` movement was added
- no worker completion, verification success, merge, pause, or resume flow was added
- no owner-repo mutation was added outside the admitted claimed queue home
- no lifecycle-advancement, deploy-readiness, or publication claim was introduced
- no widening beyond the admitted first slice was required

## Exact Next Packet

- `_stack stack queue-or-registry claim-state movement first-implementation worker proof-and-receipt packet 2`
