# GitHub Event Normalizer

`_stack` consumes the canonical Atlas GitHub event receipt contract at Atlas root commit `e05019c88f696f4efd8cdb02719e0505f3b0d64a`.

Canonical authority:

- contract id: `atlas.github.event-receipt.v1`
- canonical schema path: `packages/atlas-contracts/schemas/atlas.github.event-receipt.v1.schema.json`
- accepted canonical SHA-256: `5c4d7ec4e5d7f566ecc3f3d91fbc3344eae513acd7cbab528a0305c7953c303d`

Schema resolution order:

1. explicit operator-supplied schema path through `--schema`
2. the Atlas sibling canonical schema when `_stack` is running inside the normal `ATLAS/repos/_stack` topology
3. the repo-local mirror at `exports/github.event-receipt.schema.v1.json` only for isolated `_stack` CI

The mirror is compatibility-only, not authority. `_stack` requires byte-identical digest parity with the accepted Atlas schema and machine-readable provenance in `exports/github.event-receipt.provenance.v1.json`. If the canonical schema is missing, malformed, incompatible, or digest-shifted in the normal workspace, the normalizer fails closed instead of silently falling back.

Receipt output:

- `_stack` keeps the raw producer interface centered on `source`, `subject`, `correlation`, `evidence`, `facts`, and `payload`
- output is emitted as canonical `source`, `subject`, `correlation`, `evidence_refs`, `digest`, `normalized_facts`, and `authority`
- `event_id` and `idempotency_key` remain deterministic `ghr_` and `ghk_` identities
- payload digest conflicts stay detectable through `digest.value`
- every normalized fact preserves the exact receipt-level `fact_state`
- secret-like input is rejected before normalization and is never echoed back

Ownership boundary:

```text
_stack -> canonical GitHub event receipt
Atlas -> admission, deduplication, correlation, policy, ledger meaning
DiscordOS -> wording, routing, board/update/alert mutation, publication, readback
```

`_stack` does not format Discord messages and does not call Discord.

Operator surfaces:

- test command: `pnpm run test:github-event-normalizer`
- self-check: `pnpm run github:event-normalizer:self-check`

Next packet:

- `Atlas GitHub Event Admission Runtime`

The next seam begins after receipt production. Atlas owns admission-time packetization, durable deduplication, and later projection-intent production without changing `_stack`'s normalized receipt meaning.
