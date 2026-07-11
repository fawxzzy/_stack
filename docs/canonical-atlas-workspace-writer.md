# Canonical Atlas Workspace Writer

`codex:atlas-workspace:task` is an `_stack`-owned execution class for governed tasks that must operate directly against the canonical `C:\ATLAS` workspace root without creating a git worktree.

## Purpose

- Use it when the physical checkout location matters and Atlas topology, inventory, or lock truth must come from the real canonical root.
- Do not treat it as a widening of the existing Atlas repo-local worktree adapter.
- Do not point it at an owner worktree or any root other than an explicit canonical `ATLAS` directory.

## Entry Surface

- Command: `pnpm run codex:atlas-workspace:task -- -PromptPath C:\path\to\prompt.md -CanonicalRootPath C:\ATLAS`
- Runner: `ops/codex/Invoke-CodexCanonicalWorkspaceTask.ps1`
- Contract: `ops/codex/execution-classes/atlas-workspace.writer.json`
- Runtime defaults: `ops/codex/repos/stack/config.toml`

## Safety Contracts

- Canonical root validation is explicit and fail-closed.
  The path must be absolute, must resolve to a directory named `ATLAS`, must be the git toplevel, and must expose a real `.git` directory rather than a linked-worktree gitfile. The rejection path preserves the stable reason code `canonical_workspace_git_directory_required`.
- Mutation is read-only by default.
  A mutating prompt must explicitly admit exact repo-relative task-owned paths through `Mutation Admission Path(s)` or `Admitted Changed Path(s)` metadata, or matching explicit command arguments.
- The writer acquires an exclusive lock at `.codex/locks/atlas-workspace-writer.lock.json`.
  The lock receipts owner metadata, blocks contention, preserves stale-lock crash diagnostics, and only releases when the current run still owns the lock file.
- The writer snapshots the initial dirty inventory before execution.
  Each dirty path is receipted with status and digest so pre-existing operator-owned dirt can be preserved rather than restaged or recommitted.
- Every admitted task-owned path must start clean.
  If an admitted path is already dirty, the run fails before Codex execution.
- Pre-existing dirt must remain byte-stable.
  If a previously dirty path changes unexpectedly during the run, the writer fails closed.
- Staging is exact-path only.
  The writer stages admitted task-owned paths with `git add -- <exact path>` and then verifies the cached set. It never uses `git add .`, `git add -A`, or broad staging globs.
- Verification and spec-to-diff gates run before auto-commit.
  Push remains manual-only.

## Receipt Shape

- The writer logs to `<canonical-root>/.codex/logs/<run-id>/run.json`.
- The runtime-policy envelope is written before Codex execution begins and receipts:
  - `requested`
  - `resolved`
  - `sources`
  - `codex_version`
  - `warnings`
  - `blockers`
- The completed receipt also records:
  - `executionClass`
  - `canonicalRootValidation`
  - `lock`
  - `mutationAdmission`
  - `dirtyInventory`
  - `changedPaths`
  - `verification`
  - `commit`
  - `specToDiff`
  - `effectivePolicies`

## Diff-Addressable Acceptance Criteria

Every mutating criterion consumed by the spec-to-diff gate must be provable from literal final-diff evidence. Runtime-only assertions belong in verification receipts, not in satisfied diff criteria.

The canonical `.git` guard follows that rule directly:

- the runner resolves `Join-Path -Path $CanonicalRoot -ChildPath ".git"`
- the runner requires `Test-Path -LiteralPath $gitDirectory -PathType Container`
- the rejection path preserves `canonical_workspace_git_directory_required`

## Reusable Doctrine

`Canonical Truth Requires Canonical Topology`

- Atlas workspace truth that depends on live sibling-repo topology must run against the canonical `ATLAS` root under the canonical workspace writer.

`Preserved-Dirt Exact Staging`

- Snapshot pre-existing dirt first, freeze it by digest, derive task-owned changes afterward, and stage only the exact admitted task-owned paths.

`Worktree Topology Illusion`

- An isolated checkout can look like Atlas while still failing to represent the live canonical workspace topology that root-sensitive scripts depend on.

`Dirty-Path Capture`

- If pre-existing dirt and task-owned changes are not separated up front, automation will eventually restage or rewrite operator-owned work.

`Proof-Opaque Criterion`

- A runtime requirement can be valid and still fail governance if the final diff does not contain a literal, machine-addressable proof surface for that requirement.

## Non-Goals

- No canonical-root worktree creation
- No automatic push
- No widening of the existing Atlas adapter
- No mutation of owner repos from `_stack`
