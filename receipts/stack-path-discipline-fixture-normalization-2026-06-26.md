# _stack path-discipline fixture normalization

- date: `2026-06-26`
- scope: remove machine-specific absolute-path literals from bounded `_stack` test and operator-fixture surfaces without changing their validation intent
- guard: `No workflow widening guard: this packet may normalize test fixtures and operator-surface expectations so committed text no longer embeds machine-specific absolute paths, but it may not change admitted command scope, deploy identity, repo topology, packet validation rules, or cross-repo execution behavior.`

## Files Changed

- `scripts/data-gateway-packet-validator.test.mjs`
- `scripts/data-gateway-packet-wrapper.test.mjs`
- `ops/codex/Test-StackOperatorSurface.ps1`
- `receipts/stack-path-discipline-fixture-normalization-2026-06-26.md`

## Commands Run

- `pnpm run data-gateway:packet:validate:test`
- `pnpm run data-gateway:packet:wrapper:test`
- `powershell -NoProfile -ExecutionPolicy Bypass -File .\ops\codex\Test-StackOperatorSurface.ps1`
- `pnpm run codex:stack:verify`

## Result

- packet-validator tests still prove absolute packet refs fail closed, but the invalid absolute refs are now generated at runtime instead of hardcoded as one machine-specific ATLAS-root path
- packet-wrapper tests still prove validate-only fails closed on absolute owner-surface refs, but the invalid absolute owner path is now generated at runtime instead of hardcoded as one machine-specific ATLAS-root path
- the `_stack` operator-surface test still proves the Mazer relink guidance includes the canonical local repo path, but it now derives that path from the live repo location instead of embedding one machine-specific literal
- `powershell -NoProfile -ExecutionPolicy Bypass -File .\ops\codex\Test-StackOperatorSurface.ps1` passes after the normalization
- `pnpm run codex:stack:verify` does not expose a `_stack` failure from this packet; it stops earlier on unrelated brand consumer drift in `repos/fawxzzy-fitness` during `atlas:brand:verify`

## Notes

- this packet is fixture normalization only
- it does not change the underlying path-discipline rule, only how invalid absolute examples are materialized in tests
- it does not resolve the separate Fitness brand-consumer drift surfaced by the repo-wide verify command

## Stop Conditions Not Triggered

- no deploy or Vercel identity mutation was required
- no Fitness implementation code was touched
- no ATLAS root docs or marker surfaces were touched
- no workflow command contract changed

## Exact Next Packet

- `none inside _stack for this path-discipline fixture slice`
