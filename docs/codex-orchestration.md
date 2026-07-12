# Shared Codex Orchestration In `_stack`

`_stack` owns the shared local Codex inbox/worktree orchestration engine. Repo-specific behavior stays in thin adapter and config files so `_stack` remains an operator layer instead of becoming a second implementation surface.

`_stack` also owns one separate canonical Atlas workspace writer execution class for tasks that must operate directly against the real canonical `ATLAS` root without creating a git worktree.

## Shared Atlas Branding Assets

The `atlas:brand:*` commands resolve shared Atlas-root branding assets through the logical canonical `_stack` checkout, not from the physical depth of the current worktree. The wrapper asks Git for the common Git directory, derives the canonical `_stack` and Atlas roots, then delegates to `branding/scripts/build-brand-assets.mjs` or `branding/scripts/sync-brand-assets.mjs`. This keeps canonical and linked-worktree verification on the same assets and fails closed if the canonical script cannot be found.

`atlas:brand:sync` and `atlas:brand:verify` are `_stack` owner-scoped: they select only the `stack-launcher-icon` consumer from the canonical branding manifest. Repo-local verification follows ownership boundaries, so unrelated Fitness or Trove product-brand drift does not block an `_stack` task. `atlas:brand:sync:all` and `atlas:brand:verify:all` deliberately remain root-wide diagnostics; use them for Atlas-root brand reconciliation, never as a repo-local mutation gate.

## Responsibility Split

`_stack` owns:

- shared PowerShell runner scripts
- one shared runtime-policy resolver and invocation planner
- shared runtime defaults for model, reasoning, speed, permissions, approval, web-search, polling, exports, and git author metadata
- the adapter schema and example repo adapters
- operator-facing docs and entrypoints

Each repo still owns:

- its own inbox, archive, logs, worktrees, and exports under repo-local paths
- its own verification bootstrap and default verify commands
- its own allowed mutation surfaces and docs alignment rules
- its own push and auto-commit policy declaration through the adapter and repo config

The shared runner operates inside repo-local worktrees. It does not move repo artifacts into `_stack`.

The canonical Atlas workspace writer is intentionally different: it operates directly in the explicit canonical root, defaults to read-only, and uses exact-path mutation admission instead of broad repo-local worktree staging.

## Shared Runner Surfaces

- `ops/codex/Start-CodexInboxRunner.ps1`: watches a repo-local inbox and dispatches one prompt per worktree
- `ops/codex/Invoke-CodexRepoTask.ps1`: executes one prompt end to end
- `ops/codex/CodexRunner.Common.ps1`: common parsing, git, runtime-policy, process, prompt, archive, and logging helpers
- `ops/stack/StackWorkerArtifacts.ps1`: worker assignment/status/merge-request helpers that stamp the root stack lock digest
- `ops/stack/Test-StackWorkerArtifacts.ps1`: verification for the worker artifact contract and touched-range parsing
- `ops/codex/config.defaults.toml`: shared runtime defaults
- `ops/codex/adapter.schema.json`: thin repo adapter contract

## Runtime Policy Envelope

Rule: `Explicit Runtime Policy`

Every governed Codex job resolves and receipts its effective execution settings before it begins.

Pattern: `Runtime Policy Envelope`

One precedence-resolved policy object travels from task admission through completion.

Supported settings:

- `model`
- `reasoning`
- `speed`
- `permissions`
- `permission_profile`
- `sandbox_mode`
- `approval`
- `web_search`

Precedence:

1. explicit command argument
2. prompt metadata
3. repo-specific config
4. shared `_stack` defaults

The run manifest records the non-secret envelope at `run.json.runtimePolicy` with this stable shape:

- `requested.model`
- `requested.reasoning`
- `requested.speed`
- `requested.permissions`
- `resolved.model`
- `resolved.reasoning`
- `resolved.speed`
- `resolved.permissions`
- `resolved.approval`
- `resolved.web_search`
- `resolved.codex_version`
- `codex_version`
- `sources.model`
- `sources.reasoning`
- `sources.speed`
- `sources.permissions`
- `warnings`
- `blockers`

Failure Mode: `Hidden Runtime Drift`

This failure mode occurs when the requested model or permission posture differs from the configuration Codex actually executes. Governed jobs now block or explicitly receipt the fallback instead of silently drifting.

## Execution Model

1. The operator starts the shared runner from `_stack` with a repo config.
2. The repo config resolves the target repo root plus the adapter file.
3. The watcher reads the repo-local inbox path from the adapter and waits for settled `.md` prompt files.
4. Each prompt gets a fresh repo-local worktree and `codex/<slug>` task branch from the adapter `execution.baseRef`, resolved locally by preferring `origin/main` and falling back to local `main` when the remote-tracking ref is unavailable.
5. The runner resolves one runtime-policy envelope from explicit arguments, prompt metadata, repo config, and shared defaults before it invokes Codex.
6. The runner rejects any policy that tries to activate both a modern permission profile and a legacy sandbox mode at the same precedence level.
7. The runner capability-checks requested `fast` speed against the installed Codex model catalog. If the selected model does not advertise `fast`, the effective speed falls back to `standard` and the receipt records that fallback.
8. The runner invokes Codex non-interactively with the resolved model, reasoning, speed, permission mechanism, approval policy, and web-search posture. When the installed CLI supports version reporting, the manifest receipts that version.
9. On Windows, Codex is launched from a neutral host working directory while `-C <worktree>` still points Codex at the governed repo-local worktree. This avoids local config parsing drift without changing the target repo surface.
10. Verification bootstrap commands run first, then the effective verify list from prompt metadata or adapter defaults.
11. Adapters may also declare a proof gate that runs after the standard verify commands and fails closed when the declared status artifact is missing, unreadable, or reports `completion_ready=false`.
12. For mutating prompts that declare explicit acceptance criteria, Codex must emit a temporary spec-to-diff completion artifact before the runner can grant success.
13. The runner validates that artifact against the final repo diff and fails closed when any criterion is missing, unsupported, contradictory, skipped, failed, blocked, or otherwise unproven.
14. The runner writes `worker.assignment.json` and a running status artifact before execution, then records completion status with touched ranges when the run ends.
15. The runner blocks commit if verification fails, proof gating fails, the spec-to-diff gate fails, or changed files exceed `allowedMutationSurfaces`.
16. Successful mutating tasks auto-commit by default, skip push, export patch and optional bundle artifacts, and archive the prompt.
17. Failed runs still archive the prompt and keep worktree/log state for inspection.

## Canonical Atlas Workspace Writer

Execution class: `canonical_workspace`

Purpose:

- operate directly against the canonical `ATLAS` root when physical-root-sensitive Atlas scripts or topology truth cannot be reproduced from a worktree
- keep that path separate from the existing repo-local Atlas adapter

Entry surfaces:

- `pnpm run codex:atlas-workspace:task -- -PromptPath C:\path\to\prompt.md -CanonicalRootPath C:\ATLAS`
- `ops/codex/Invoke-CodexCanonicalWorkspaceTask.ps1`
- `ops/codex/execution-classes/atlas-workspace.writer.json`

Execution model:

1. The operator supplies an explicit absolute canonical root path.
2. The runner validates that the path resolves to a directory named `ATLAS`, is the git toplevel, and uses a real `.git` directory instead of a linked-worktree gitfile. Non-directory `.git` entries fail with `canonical_workspace_git_directory_required`.
3. The runner acquires `.codex/locks/atlas-workspace-writer.lock.json` with owner metadata and stale-lock diagnostics.
4. The runner snapshots the initial dirty inventory with digests before Codex execution.
5. The runner fails closed if any admitted task-owned path is already dirty or if pre-existing dirt is already staged.
6. Mutation stays read-only unless the prompt or explicit arguments admit exact repo-relative task-owned paths.
7. Codex runs directly against the canonical root with the shared runtime-policy envelope and the same spec-to-diff and commit metadata contracts used by the worktree runner.
8. After Codex exits, the runner verifies that pre-existing dirt is unchanged, rejects any unadmitted task-owned changes, stages only exact admitted paths, and keeps push manual-only.

Safety contracts:

- no git worktree creation
- read-only default
- exact-path mutation admission only
- digest-backed dirt preservation
- exact-path staging only
- manual-only push

The detailed operator contract, diff-addressable acceptance-criteria guidance, and canonical-topology doctrine live in `docs/canonical-atlas-workspace-writer.md`.

## Adapter Contract

The adapter contract is JSON and intentionally thin:

- `verify.bootstrapCommands`: fresh-worktree bootstrap before verification
- `verify.defaultCommands`: default verification when the prompt does not supply `Verify:` lines
- `verify.proofGate`: optional post-verify completion gate that consumes a machine-readable status artifact
- `allowedMutationSurfaces`: fail-closed mutation boundary
- `docsUpdateRules`: repo-specific documentation alignment rules
- `artifacts`: repo-local inbox/archive/log/worktree/export paths
- `exports`: patch and bundle policy plus patch base ref
- `pushPolicy`: must stay manual-only unless a repo explicitly opts out later
- `autoCommitPolicy`: explicit commit behavior for successful mutating runs, including the commit metadata contract
- `localLandingPolicy`: optional local post-commit landing policy for bringing a successful task commit back onto local `main` without pushing
- `stack worker artifacts`: `_stack` jobs emit assignment, running status, merge-request, and completion status artifacts, all stamped with the root `stack_lock_digest`
- `execution`: base ref, branch prefix, worktree cleanup/fetch toggles, and optional repo-local verification settings

Schema file:

- `ops/codex/adapter.schema.json`

Runtime policy now lives in config rather than the adapter schema:

- shared defaults: `ops/codex/config.defaults.toml`
- repo overrides: `ops/codex/repos/<repo>/config.toml`

## Thin Repo Config

Each repo config should normally stay minimal:

```toml
repo_root = "../../../../../playbook"
adapter_path = "./adapter.json"

[runtime_policy]
model = "gpt-5.4"
reasoning = "high"
speed = "standard"
permissions = "workspace-write"
sandbox_mode = "workspace-write"
approval = "never"
web_search = "disabled"
```

Shared defaults come from `ops/codex/config.defaults.toml`. Repo configs only need to add overrides when a repo truly needs different runtime behavior.

## Repo Adapter Examples

Playbook is the first extracted adapter:

- config: `ops/codex/repos/playbook/config.toml`
- adapter: `ops/codex/repos/playbook/adapter.json`

This preserves the pilot behavior while moving the engine into `_stack`:

- repo-local inbox/archive/log/worktree/export paths remain under Playbook `.codex/`
- Playbook verification bootstrap and docs audit stay Playbook-specific
- mutation scope is now a narrow changelog-generator exception: `.codex/**`, `packages/engine/src/release/changelog/**`, `packages/engine/src/release/index.ts`, `packages/engine/src/index.ts`, `packages/cli/src/commands/changelog/**`, `packages/cli/src/commands/changelog.ts`, `packages/cli/src/commands/index.ts`, `packages/cli/src/lib/commandMetadata.ts`, `docs/CHANGELOG-GENERATOR.md`, `docs/RELEASING.md`, `docs/CHANGELOG.md`, `.github/workflows/changelog.yml`, `CHANGELOG-GENERATOR-PLAN.md`, and `docs/codex/CHANGELOG-GENERATOR-PLAN.md`
- broad globs such as `packages/**`, `packages/engine/**`, `packages/cli/**`, `.github/**`, and `docs/**` remain intentionally disallowed
- push remains manual-only
- auto-commit remains enabled by default for successful mutating tasks

Atlas is the first non-Playbook extracted adapter:

- config: `ops/codex/repos/atlas/config.toml`
- adapter: `ops/codex/repos/atlas/adapter.json`

Atlas stays intentionally thin:

- repo-local inbox/archive/log/worktree/export paths remain under Atlas `.codex/`
- verification now includes the root-owned UI drift, visual proof, and proof-summary tests plus a proof gate over the derived completion summary
- mutation scope stays limited to Atlas docs, `.codex/`, root-owned validation/projection tooling under `ops/**`, `schemas/**`, and `tests/**`, plus `README.md`
- docs rules keep architecture and boundary docs aligned while preserving the rule that Atlas validates and projects rather than owning UI primitive truth
- push remains manual-only
- auto-commit remains enabled by default for successful mutating tasks

Lifeline is the next thin non-Vercel extracted adapter:

- config: `ops/codex/repos/lifeline/config.toml`
- adapter: `ops/codex/repos/lifeline/adapter.json`

Lifeline stays intentionally repo-local:

- repo-local inbox/archive/log/worktree/export paths remain under Lifeline `.codex/`
- verification bootstraps with `pnpm install --frozen-lockfile` and then uses the repo's grouped typecheck, build, deterministic-suite, and smoke-suite commands
- mutation scope stays limited to Lifeline source, scripts, fixtures, examples, docs, core repo config, and explicit workflow files; generated runtime state and push automation remain out of scope
- docs rules keep runtime, manifest, startup-contract, and testing docs aligned with README and changelog when Lifeline behavior changes
- push remains manual-only
- auto-commit remains enabled by default for successful mutating tasks using the shared commit metadata artifact contract

DiscordOS is a first-class owner adapter:

- config: `ops/codex/repos/discordos/config.toml`
- adapter: `ops/codex/repos/discordos/adapter.json`
- commands: `pnpm run codex:discordos:inbox`, `pnpm run codex:discordos:inbox:once`, and `pnpm run codex:discordos:task -- -PromptPath C:\path\to\prompt.md`

`_stack` is the execution operator only. DiscordOS remains the single logical canonical board and Discord writer. Its fresh worktrees bootstrap with `npm ci` and use the owner’s default verification set; this preparation task does not execute those commands or a DiscordOS task.

Authority remains explicit:

- host capability does not authorize Discord, deployment, production, or live-data access
- a live-write claim requires production-environment readiness and exact bot-backed readback of the target channel, thread, or card
- the next governed canary is no-send; it must not send a message or mutate a board card
- Vercel production deploy, promotion, rollback, or alias cutover requires explicit approval in the current thread for the named project; generic approval is not sufficient

Push stays manual-only, successful verified mutations auto-commit, and DiscordOS local landing stays disabled.

`_stack` is also a first-class self-managed adapter:

- config: `ops/codex/repos/stack/config.toml`
- adapter: `ops/codex/repos/stack/adapter.json`

`_stack` stays intentionally operator-only while using the same runner path it hosts:

- repo-local inbox/archive/log/worktree/export paths resolve under `_stack/.codex/`
- verification stays lightweight and checks required operator files, `_stack` Codex scripts/tasks, worker artifacts, and whitespace safety with `git diff --check`
- `git diff --check` remains hygiene only; it is not proof that the requested source edits were applied
- mutation scope stays limited to `_stack` operator surfaces such as `ops/**`, `docs/**`, `.vscode/**`, templates, queue, receipts scaffolding, and repo metadata
- `_stack` admits `exports/**` and `tests/**` only for `_stack`-owned contract evidence, repo-owned adoption exports, verification reports, schemas, and deterministic owner tests. This does not authorize product or application implementation, or cross-repo writes.
- docs rules keep README, orchestration docs, dispatcher docs, workspace manifest, and handoff templates aligned when `_stack` runner behavior or workflow boundaries change
- governed `_stack` jobs default to `permissions = "full-access"` with the modern `permission_profile = ":danger-full-access"` from repo config
- the last accepted bootstrap path remains available through explicit legacy `sandbox_mode = "danger-full-access"` entrypoints for compatibility with existing callers
- push remains manual-only
- local landing is enabled only for `_stack`, using `ff-only` to bring a successful task commit back onto local `main` when the repo-root worktree is safe to advance
- auto-commit remains enabled by default for successful mutating tasks using the same commit metadata artifact contract

## Spec-To-Diff Gate

Pattern: `Spec-to-Diff Verification Gate`

For mutating prompts that declare explicit acceptance criteria, the runner requires a temporary completion artifact under `.codex/` with one entry per criterion. A task is completion-ready only when every criterion is explicitly accounted for and each `satisfied` criterion is provable from the final repo diff.

Rule details:

- summary text is never proof
- changed-path presence alone is never proof
- `git diff --check` is hygiene only
- visual diffs and proof-gate screenshots are screenshot proof, not source-edit proof
- blocked, skipped, and failed criteria keep the task out of the success path
- expected unchanged paths must remain unchanged unless the completion artifact provides an explicit justification
- mutating Codex tasks are not considered governed unless they declare acceptance criteria
- legacy mutating prompts remain on the compatibility path until they are converted to the acceptance-criteria contract

Failure Mode: `Summary-Truth Drift`

This failure mode occurs when a worker summary claims the requested change is complete but the repository diff does not prove that every explicit requested edit was applied.

## Auto-Commit, Landing, And Push Policy

Default behavior is explicit and fail-closed:

- successful mutating tasks auto-commit
- no-change tasks do not create empty commits
- verification failure blocks commit
- spec-to-diff proof failure blocks commit
- mutation-scope failure blocks commit
- base-ref resolution is local-first: prefer configured `origin/<branch>` when it exists locally, otherwise fall back to the matching local branch name
- local landing is adapter-controlled and defaults to disabled
- `_stack` currently opts into `ff-only` landing to local `main`
- `ff-only` landing requires the repo-root worktree to already be on local `main`, to be clean, and to be able to fast-forward to the task commit
- if landing is unsafe or fast-forward is not possible, the runner leaves the commit on the task branch and records the reason in the run log
- push stays manual-only and skipped by default

The runner records the configured and resolved base refs, resolved patch export base ref, commit metadata decision, final commit message, adapter data, task branch, commit sha, landing mode, `landed_to_main`, and any landing failure reason in each repo-local `run.json` manifest.

## Commit Metadata Contract

The shared runner asks Codex for structured commit metadata in a temporary repo-local artifact:

- default artifact path: `.codex/commit-meta.json`
- JSON shape: `{"type":"<type>","scope":"<scope>","summary":"<summary>"}`
- minimum allowed types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`
- scope must be a short lowercase slug
- summary must be specific and non-generic

The runner validates `type`, `scope`, and `summary` before commit. Generic summaries like `update`, `done`, `fixes`, and `misc changes` are rejected and replaced through deterministic fallback generation.

The artifact is temporary:

- Codex writes it inside the repo worktree
- the runner reads it after Codex exits
- the runner removes it before staging so the artifact itself does not become the change

If Codex does not provide valid metadata, the runner falls back deterministically:

- scope falls back to the adapter repo id unless the adapter overrides it
- type falls back from changed-file surfaces, with docs-only changes resolving to `docs`, test-only changes resolving to `test`, config-only changes resolving to `chore`, and other mixed/code changes resolving to `feat` unless prompt intent clearly indicates `fix` or `refactor`
- summary falls back first to the prompt title when it validates, otherwise to a surface-derived phrase such as `update architecture planning docs` or `add shared codex runner support`

The runner writes commit trace artifacts into the run log directory:

- `commit-meta.raw.json` when Codex provided the artifact
- `commit-meta.resolved.json` with the validated or fallback metadata
- `commit-message.txt` with the final message used for commit
- `worker.assignment.json`, `worker.status.running.json`, and `worker.status.completed.json` for worker lifecycle tracking

For mutating prompts with acceptance criteria, the runner also asks Codex for a temporary spec-to-diff completion artifact:

- default artifact path: `.codex/spec-to-diff-proof.json`
- required contract version: `atlas.stack.spec_to_diff.v1`
- one entry per acceptance criterion
- allowed statuses: `satisfied`, `skipped`, `failed`, `blocked`

The runner copies the raw artifact into the run log, validates it against the final diff, then removes the temporary worktree artifact before staging. Missing, unreadable, or unproven completion proof blocks success and commit.

Push remains manual-only. This pass does not add any auto-push or multi-repo dispatch behavior.

## Runtime Posture

## Native CLI And Model Capability Contract

On Windows, both governed execution classes select Codex in this order: explicit `-CodexCommand`, merged `[windows].codex_command`, then native PATH fallback. The shared and repo-local default is the user-global native executable `%APPDATA%/npm/node_modules/@openai/codex/node_modules/@openai/codex-win32-x64/vendor/x86_64-pc-windows-msvc/bin/codex.exe`.

Configured values are environment-expanded before resolution. A missing path, wrapper, shim, or non-native executable fails closed before policy probing or execution. Each receipt includes `requestedPath`, `expandedPath`, `resolvedNativePath`, `source`, and `codex_version`.

Before execution, the same resolved native executable performs a repository-read-only model capability probe. Its only outcomes are `accepted`, `unsupported_model`, `unavailable`, and `probe_failed`; no static model catalog is used. Runtime receipts preserve `requested_model`, `effective_model`, and `model_capability` so effective model truth comes from the probe.

Shared defaults keep legacy `workspace-write` compatibility through `sandbox_mode = "workspace-write"`.

Repo overrides may switch to the modern permission mechanism:

- `_stack` defaults to `permissions = "full-access"` and `permission_profile = ":danger-full-access"`
- bootstrap compatibility remains available through explicit legacy `danger-full-access` entrypoints
- modern permission profiles and legacy sandbox modes must never be active together in the same effective policy

## Example Commands

Run the Atlas watcher:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\ops\codex\Start-CodexInboxRunner.ps1 -ConfigPath .\ops\codex\repos\atlas\config.toml
```

Run Atlas inbox processing once:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\ops\codex\Start-CodexInboxRunner.ps1 -ConfigPath .\ops\codex\repos\atlas\config.toml -RunOnce
```

Run one Atlas prompt directly:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\ops\codex\Invoke-CodexRepoTask.ps1 -ConfigPath .\ops\codex\repos\atlas\config.toml -PromptPath C:\path\to\prompt.md
```

Run one canonical Atlas workspace prompt directly:

```powershell
pnpm run codex:atlas-workspace:task -- -PromptPath C:\path\to\prompt.md -CanonicalRootPath C:\ATLAS
```

Run the Playbook watcher:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\ops\codex\Start-CodexInboxRunner.ps1 -ConfigPath .\ops\codex\repos\playbook\config.toml
```

Run the Lifeline watcher:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\ops\codex\Start-CodexInboxRunner.ps1 -ConfigPath .\ops\codex\repos\lifeline\config.toml
```

Run the DiscordOS watcher:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\ops\codex\Start-CodexInboxRunner.ps1 -ConfigPath .\ops\codex\repos\discordos\config.toml
```

Run DiscordOS inbox processing once:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\ops\codex\Start-CodexInboxRunner.ps1 -ConfigPath .\ops\codex\repos\discordos\config.toml -RunOnce
```

Run one DiscordOS prompt directly:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\ops\codex\Invoke-CodexRepoTask.ps1 -ConfigPath .\ops\codex\repos\discordos\config.toml -PromptPath C:\path\to\prompt.md
```

Run one specific prompt directly:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\ops\codex\Invoke-CodexRepoTask.ps1 -ConfigPath .\ops\codex\repos\playbook\config.toml -PromptPath C:\path\to\prompt.md
```

Run the `_stack` watcher:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\ops\codex\Start-CodexInboxRunner.ps1 -ConfigPath .\ops\codex\repos\stack\config.toml
```

Run `_stack` inbox processing once:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\ops\codex\Start-CodexInboxRunner.ps1 -ConfigPath .\ops\codex\repos\stack\config.toml -RunOnce
```

Run the last accepted static-model bootstrap policy explicitly:

```powershell
pnpm run codex:stack:inbox:bootstrap:once
```

Run one `_stack` prompt directly with the same bootstrap posture:

```powershell
pnpm run codex:stack:task:bootstrap -- -PromptPath C:\path\to\prompt.md
```

Override runtime policy explicitly for a governed direct task:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\ops\codex\Invoke-CodexRepoTask.ps1 -ConfigPath .\ops\codex\repos\stack\config.toml -PromptPath C:\path\to\prompt.md -Model gpt-5.4 -Reasoning high -Speed standard -PermissionProfile :danger-full-access -ApprovalPolicy never -WebSearch disabled
```

Use a legacy sandbox override only for explicit compatibility paths:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\ops\codex\Invoke-CodexRepoTask.ps1 -ConfigPath .\ops\codex\repos\stack\config.toml -PromptPath C:\path\to\prompt.md -SandboxMode danger-full-access
```

## Non-Goals For This Pass

- no dev-root orchestrator
- no Fitness deploy-script changes
- no repo implementation refactors outside the named operator surfaces
