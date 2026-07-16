# Workflow Pack Reuse Contract

This document freezes the reusable Playbook workflow-pack boundary for downstream repos and control planes.

It does not create a new command family or alternate runtime. It declares which existing Playbook contracts are reusable as one bundle and which responsibilities remain outside the bundle.

## Reuse decision

The reusable workflow pack is the combination of:

- local-first verification truth
- staged workflow promotion truth
- deterministic export/discovery surfaces
- additive schema/version governance
- consumer usage rules

The workflow pack is reusable as a bundle. Downstream repos and operator layers should consume these contracts together instead of cherry-picking fields into app-local mirrors.

## Canonical bundle members

### 1. Local verification contract

- Owner contract: `docs/contracts/LOCAL_VERIFICATION_RECEIPT_CONTRACT.md`
- Schema: `packages/contracts/src/local-verification-receipt.schema.json`
- Primary command surfaces:
  - `pnpm playbook verify --local --json`
  - `pnpm playbook verify --local-only --json`
- Durable artifacts:
  - `.playbook/local-verification-receipt.json`
  - `.playbook/local-verification-receipts.json`
  - `.playbook/local-verification/*.stdout.log`
  - `.playbook/local-verification/*.stderr.log`

This contract owns verification truth only. Publishing and deployment remain adjacent workflow fields, not verification authority.

### 2. Workflow promotion contract

- Owner contract: `docs/contracts/WORKFLOW_PROMOTION_CONTRACT.md`
- Schemas:
  - `packages/contracts/src/workflow-promotion.schema.json`
  - `packages/contracts/src/promotion-receipt.schema.json`
- Current adopter surfaces:
  - `pnpm playbook status updated --json`
  - `pnpm playbook route --json`

This contract owns staged candidate -> validation -> promotion metadata for repo-visible writes. It does not redefine the business meaning of the promoted artifact itself.

### 3. Export and discovery surface

- Owner command surface: `pnpm playbook contracts --json`
- Owner contract: `docs/contracts/CONTRACT_REGISTRY_V1.md`
- Default registry artifact: `.playbook/contracts-registry.json`

Consumers should discover workflow-pack schemas, runtime defaults, and contract-doc availability through the contract registry instead of hard-coding file inventories in each downstream repo.

## Inputs and outputs

The reusable workflow pack has these input/output rules:

- Inputs must resolve through canonical Playbook commands or canonical artifact paths already named by the owning contracts.
- Outputs must remain deterministic, schema-versioned, and inspectable on disk.
- Verification outputs and promotion outputs are separate contracts and must not be collapsed into one synthetic status field.
- If a workflow needs both verification and promotion truth, it must compose the two contracts explicitly instead of inventing a third ad hoc summary format.
- Consumer-side compatibility gates may also compose external proof artifacts, but those projections must stay read-only and must preserve refs back to the underlying owner reports instead of replacing them.

## Versioning

- Shared versioning policy: `docs/contracts/ARTIFACT_EVOLUTION_POLICY.md`
- Compatibility model: additive changes are allowed within the current schema major; breaking changes require a schema-version bump.
- Registry expectation: contract/schema additions must be registered in `pnpm playbook contracts`.

## Consumer rules

- Shared downstream rules: `docs/CONSUMER_INTEGRATION_CONTRACT.md`
- Consumer repos must treat Playbook as shared core plus project-local `.playbook/*` state.
- Consumer repos and stack operators must not duplicate or reinterpret workflow-pack contracts into divergent local specs.
- Compatibility mirrors are allowed only when they preserve the same canonical fields, types, and semantics.
- If a downstream surface cannot consume the canonical contract directly, it may publish a mirror or projection only as a clearly declared compatibility layer, not as new owner truth.
- The reusable `.github/actions/atlas-ui-proof/action.yml` surface is one such compatibility layer: it consumes ATLAS-owned semantic drift and visual proof, then exposes a derived completion-facing summary without redefining Playbook verification truth.

## Non-goals

This workflow pack does not include:

- provider-specific CI workflow YAML as canonical truth
- deployment-specific runtime handoff contracts
- app-local telemetry/event naming
- privileged execution lineage or approval semantics owned by Lifeline
- stack orchestration semantics owned by `_stack`

## Rule

- Reusable workflow adoption must compose canonical verification, promotion, registry, and consumer contracts instead of creating repo-local workflow dialects.

## Pattern

- Freeze the reusable bundle once, then let downstream repos adopt it through the contract registry and owner docs.

## Failure Mode

- Downstream repos reusing only fragments of the workflow pack create semantic drift: verification truth, promotion truth, versioning, and consumer boundaries stop agreeing even when field names still look familiar.
