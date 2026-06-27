# _stack stack queue-or-registry launch-or-dispatch first implementation worker proof-and-receipt packet 2

- date: `2026-06-13`
- scope: first admitted `_stack` `stack queue-or-registry launch-or-dispatch` implementation slice proof hardening only
- guard: `No-completion guard: this packet may admit future implementation of one explicit launch-or-dispatch wrapper input parser, one root-relative ref normalization layer for pending-queue-drop or stack-runner-config or dispatch-inbox-root or dispatch-logs-root refs, one bounded prompt-copy staging write into the admitted repo-local inbox home, one bounded _stack runner start invocation, one bounded wrapper report renderer, and one fail-closed lineage-mismatch or invalid-dispatch-inbox-root or invalid-dispatch-logs-root or prompt-stage-write-failed or worker-start-artifacts-missing handler, but it may not mutate or remove the original pending queue drop, move files into claimed or done queue homes, inspect ambient queue or inbox or historical log state, claim worker completion or verification success or commit success, invoke merge or pause or resume flows, mutate owner-repo surfaces outside the admitted _stack inbox and logs homes, or imply lifecycle advancement, deploy readiness, or publication proof.`

## Files Changed

- `scripts/queue-or-registry-launch-or-dispatch.test.mjs`
- `receipts/stack-queue-or-registry-launch-or-dispatch-first-implementation-worker-proof-and-receipt-packet-2-2026-06-13.md`

## Commands Run

- `node --test .\scripts\queue-or-registry-launch-or-dispatch.test.mjs`
- `powershell -NoProfile -ExecutionPolicy Bypass -File .\ops\codex\Test-StackOperatorSurface.ps1`
- `pnpm run codex:stack:verify`
- `python ops\validation\validate_stack.py --ratchet`

## Result

- first-slice implementation remains landed cleanly
- proof hardening now locks bounded absolute-path discipline for `--pending-queue-drop` before any file loading
- proof hardening now locks required success-envelope field presence on bounded launch-start success output
- proof hardening now locks success-only field absence on fail-closed outputs so launch failures cannot drift into partial success narration
- proof hardening now locks governed-lineage contradiction handling between the pending queue drop and the emitted assignment/running pair
- proof hardening now locks malformed helper-output rejection when the admitted helper omits the required staged prompt or worker-start refs

## Proof Cases

- valid explicit pending drop plus bounded inbox/logs home plus one assignment/running pair -> `launch-started`
- pending queue drop outside `repos/_stack/queue/pending/` -> `invalid-pending-queue-drop`
- malformed stack runner config ref -> `invalid-stack-runner-config`
- dispatch inbox root outside `repos/_stack/.codex/inbox/` -> `invalid-dispatch-inbox-root`
- dispatch logs root outside `repos/_stack/.codex/logs/` -> `invalid-dispatch-logs-root`
- absolute pending queue drop path -> `invalid-pending-queue-drop`
- contradictory stack lock digest -> `lineage-mismatch`
- contradictory governed lineage -> `lineage-mismatch`
- bounded staging failure -> `prompt-stage-write-failed`
- bounded runner start failure before usable worker-start output -> `launch-start-failed`
- missing emitted worker-start artifacts -> `worker-start-artifacts-missing`
- malformed emitted helper output -> `malformed-worker-start-output`
- required success fields present -> pass
- success-only fields absent on failure -> pass

## Notes

- this packet did not widen the first admitted slice
- this packet did not change command semantics, admitted evidence classes, or routing-note vocabulary
- this packet tightens four proof-discipline boundaries:
  - absolute input-path rejection happens before any file loading
  - bounded success output must preserve the full admitted launch-start envelope
  - bounded failures omit success-only fields instead of drifting into partial success shape
  - emitted helper refs and governed lineage must remain usable and contradiction-free

## Stop Conditions Not Triggered

- no original pending queue drop mutation was required
- no `claimed/` or `done/` queue movement was required
- no worker completion, verification success, merge, pause, or resume flow was required
- no owner-repo mutation was added outside the admitted `_stack` inbox and logs homes
- no lifecycle-advancement, deploy-readiness, or publication claim was introduced
- no widening beyond the admitted first slice was required

## Exact Next Packet

- `launch-or-dispatch packet-2 root reconciliation`
