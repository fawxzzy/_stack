# _stack stack queue-or-registry claim-state movement first implementation worker proof-and-receipt packet 2

- date: `2026-06-13`
- scope: first admitted `_stack` `stack queue-or-registry claim-state movement` implementation slice proof hardening only
- guard: `No-completion guard: this packet may admit future implementation of one explicit claim-state-movement wrapper input parser, one root-relative ref normalization layer for pending-queue-drop or worker-assignment or worker-running-status or claimed-queue-root refs, one bounded pending-to-claimed move into the admitted claimed queue home, one bounded wrapper report renderer, and one fail-closed lineage-mismatch or active-worker-mismatch or invalid-claimed-queue-root or claim-move-failed or malformed-claim-output handler, but it may not inspect ambient queue or historical worker state, move files into done queue homes, claim worker completion or verification success or commit success, invoke merge or pause or resume flows, mutate owner-repo surfaces outside the admitted claimed queue home, or imply lifecycle advancement, deploy readiness, or publication proof.`

## Files Changed

- `scripts/queue-or-registry-claim-state-movement.test.mjs`
- `receipts/stack-queue-or-registry-claim-state-movement-first-implementation-worker-proof-and-receipt-packet-2-2026-06-13.md`

## Commands Run

- `node --test .\scripts\queue-or-registry-claim-state-movement.test.mjs`
- `pnpm run codex:stack:verify`
- `python ops\stack\generate_lockfile.py`
- `python ops\validation\validate_stack.py --ratchet`

## Result

- first-slice implementation remains landed cleanly
- proof hardening now locks bounded absolute-path rejection for `--worker-assignment` before any file loading
- proof hardening now locks lineage contradiction handling when the running-status artifact carries a conflicting `stack_lock_digest`
- proof hardening now locks malformed claim-output rejection when the emitted `claim_movement_artifact` omits the admitted array-shaped `source_artifact_refs`
- dedicated claim-state proof now passes at `13` tests
- repo-local `_stack` verify stayed clean
- root validation stayed clean at:
  - `critical=0 error=0 warning=0 info=0`

## Proof Cases

- valid explicit pending drop plus one valid active-worker proof pair plus one valid claimed queue home -> `claim-moved`
- pending queue drop outside `repos/_stack/queue/pending/` -> `invalid-pending-queue-drop`
- malformed worker assignment -> `invalid-worker-assignment`
- absolute worker-assignment path -> `invalid-worker-assignment`
- malformed or non-running worker status -> `invalid-worker-running-status`
- claimed queue root outside `repos/_stack/queue/claimed/` -> `invalid-claimed-queue-root`
- contradictory governed lineage -> `lineage-mismatch`
- contradictory running-status `stack_lock_digest` -> `lineage-mismatch`
- contradictory worker identity between assignment and running status -> `active-worker-mismatch`
- unusable bounded claimed target -> `claim-move-failed`
- malformed emitted claim output with wrong claimed drop ref -> `malformed-claim-output`
- malformed emitted claim output with missing required claim-artifact field shape -> `malformed-claim-output`
- bounded text rendering success path -> pass

## Notes

- this packet did not widen the first admitted slice
- this packet did not change command semantics, admitted evidence classes, or routing-note vocabulary
- this packet tightens three proof-discipline boundaries:
  - absolute input-path rejection for worker-assignment now stays explicitly fail-closed before file loading
  - running-status lock-digest contradiction now stays explicitly fail-closed as lineage drift rather than helper-shape ambiguity
  - emitted claim artifacts must preserve the admitted required field shapes rather than merely returning a syntactically partial success payload

## Stop Conditions Not Triggered

- no queue history or worker history scans were required
- no `queue/done/` movement was required
- no worker completion, verification success, merge, pause, or resume flow was required
- no owner-repo mutation was added outside the admitted claimed queue home
- no lifecycle-advancement, deploy-readiness, or publication claim was introduced
- no widening beyond the admitted first slice was required

## Exact Next Packet

- `claim-state-movement packet-2 root reconciliation`
