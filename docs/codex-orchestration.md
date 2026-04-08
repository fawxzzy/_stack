# Shared Codex Orchestration In `_stack`

`_stack` now owns the shared local Codex inbox/worktree orchestration engine. Repo-specific behavior stays in thin adapter and config files so `_stack` remains an operator layer instead of becoming a dev-root mega-runner.

## Responsibility split

`_stack` owns:

- shared PowerShell runner scripts
- shared runtime defaults for model, sandbox, approval, polling, exports, and git author metadata
- the adapter schema and example repo adapters
- operator-facing docs and entrypoints

Each repo still owns:

- its own inbox, archive, logs, worktrees, and exports under repo-local paths
- its own verification bootstrap and default verify commands
- its own allowed mutation surfaces and docs alignment rules
- its own push and auto-commit policy declaration through the adapter

The shared runner operates inside repo-local worktrees. It does not move repo artifacts into `_stack`.

## Shared runner surfaces

- `ops/codex/Start-CodexInboxRunner.ps1`: watches a repo-local inbox and dispatches one prompt per worktree
- `ops/codex/Invoke-CodexRepoTask.ps1`: executes one prompt end to end
- `ops/codex/CodexRunner.Common.ps1`: common parsing, git, process, prompt, archive, and logging helpers
- `ops/codex/config.defaults.toml`: shared runtime defaults
- `ops/codex/adapter.schema.json`: thin repo adapter contract

## Execution model

1. The operator starts the shared runner from `_stack` with a repo config.
2. The repo config resolves the target repo root plus the adapter file.
3. The watcher reads the repo-local inbox path from the adapter and waits for settled `.md` prompt files.
4. Each prompt gets a fresh repo-local worktree and `codex/<slug>` task branch from the adapter `execution.baseRef`.
5. Codex runs non-interactively inside that worktree.
6. Verification bootstrap commands run first, then the effective verify list from prompt metadata or adapter defaults.
7. The runner blocks commit if verification fails or if changed files exceed `allowedMutationSurfaces`.
8. Successful mutating tasks auto-commit by default, skip push, export patch and optional bundle artifacts, and archive the prompt.
9. Failed runs still archive the prompt and keep worktree/log state for inspection.

## Adapter contract

The adapter contract is JSON and intentionally thin:

- `verify.bootstrapCommands`: fresh-worktree bootstrap before verification
- `verify.defaultCommands`: default verification when the prompt does not supply `Verify:` lines
- `allowedMutationSurfaces`: fail-closed mutation boundary
- `docsUpdateRules`: repo-specific documentation alignment rules
- `artifacts`: repo-local inbox/archive/log/worktree/export paths
- `exports`: patch and bundle policy plus patch base ref
- `pushPolicy`: must stay manual-only unless a repo explicitly opts out later
- `autoCommitPolicy`: explicit commit behavior for successful mutating runs, including the commit metadata contract
- `execution`: base ref, branch prefix, sandbox default, documented Windows fallback, and worktree cleanup/fetch toggles

Schema file:

- `ops/codex/adapter.schema.json`

## Thin repo config

Each repo config should normally stay minimal:

```toml
repo_root = "../../../../../fawxzzy-playbook"
adapter_path = "./adapter.json"
```

Shared defaults come from `ops/codex/config.defaults.toml`. Repo configs only need to add overrides when a repo truly needs different runtime behavior.

## Repo adapter examples

Playbook is the first extracted adapter:

- config: `ops/codex/repos/playbook/config.toml`
- adapter: `ops/codex/repos/playbook/adapter.json`

This preserves the pilot behavior while moving the engine into `_stack`:

- repo-local inbox/archive/log/worktree/export paths remain under Playbook `.codex/`
- Playbook verification bootstrap and docs audit stay Playbook-specific
- mutation scope stays limited to Playbook docs, `.codex/`, `README.md`, and `scripts/codex-*.ps1`
- push remains manual-only
- auto-commit remains enabled by default for successful mutating tasks

Atlas is the first non-Playbook extracted adapter:

- config: `ops/codex/repos/atlas/config.toml`
- adapter: `ops/codex/repos/atlas/adapter.json`

Atlas stays intentionally thin:

- repo-local inbox/archive/log/worktree/export paths remain under Atlas `.codex/`
- verification stays docs-first and lightweight with no package bootstrap
- mutation scope stays limited to Atlas docs, `.codex/`, and `README.md`
- docs rules keep architecture and boundary docs aligned without importing `_stack` command logic
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

## Auto-commit and push policy

Default behavior is explicit and fail-closed:

- successful mutating tasks auto-commit
- no-change tasks do not create empty commits
- verification failure blocks commit
- mutation-scope failure blocks commit
- push stays manual-only and skipped by default

The runner records the resolved policy, commit metadata decision, final commit message, and adapter data in each repo-local `run.json` manifest.

## Commit metadata contract

The shared runner now asks Codex for structured commit metadata in a temporary repo-local artifact:

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

Push remains manual-only. This pass does not add any auto-push or multi-repo dispatch behavior.

## Windows sandbox posture

Shared defaults use `workspace-write`. The documented Windows fallback remains `danger-full-access`, but only as an operator override or per-repo documented fallback. It is not the shared default.

## Example commands

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

Run the Playbook watcher:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\ops\codex\Start-CodexInboxRunner.ps1 -ConfigPath .\ops\codex\repos\playbook\config.toml
```

Run the Lifeline watcher:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\ops\codex\Start-CodexInboxRunner.ps1 -ConfigPath .\ops\codex\repos\lifeline\config.toml
```

Run Lifeline inbox processing once:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\ops\codex\Start-CodexInboxRunner.ps1 -ConfigPath .\ops\codex\repos\lifeline\config.toml -RunOnce
```

Run one Lifeline prompt directly:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\ops\codex\Invoke-CodexRepoTask.ps1 -ConfigPath .\ops\codex\repos\lifeline\config.toml -PromptPath C:\path\to\prompt.md
```

Run Playbook inbox processing once:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\ops\codex\Start-CodexInboxRunner.ps1 -ConfigPath .\ops\codex\repos\playbook\config.toml -RunOnce
```

Run one specific prompt directly:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\ops\codex\Invoke-CodexRepoTask.ps1 -ConfigPath .\ops\codex\repos\playbook\config.toml -PromptPath C:\path\to\prompt.md
```

Use a sandbox override only when the shared default fails in an already sandboxed environment:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\ops\codex\Start-CodexInboxRunner.ps1 -ConfigPath .\ops\codex\repos\playbook\config.toml -RunOnce -SandboxMode danger-full-access
```

## Non-goals for this pass

- no dev-root orchestrator
- no Fitness deploy-script changes
- no repo implementation refactors outside the named operator surfaces
