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

## Native Codex Resolution

- On Windows, the writer resolves the Codex executable with exact precedence: explicit `-CodexCommand`, then merged `[windows].codex_command`, then native PATH fallback.
- Configured command strings still use the repo task runner expansion semantics: `${HOME}` and environment variables are expanded before resolution.
- The Windows PATH fallback is native-only and prefers `codex.exe` before `codex`.
- The writer never passes a PowerShell shim, `.cmd`, `.bat`, extensionless npm shim, or any other non-native wrapper directly to `ProcessStartInfo.FileName` while `UseShellExecute=false`.
- Invalid pre-execution resolution fails closed with stable reason codes: `canonical_workspace_codex_native_executable_required` or `canonical_workspace_codex_native_executable_not_found`.

## Safety Contracts

- Canonical root validation is explicit and fail-closed.
  The path must be absolute, must resolve to a directory named `ATLAS`, must be the git toplevel, and must expose a real `.git` directory rather than a linked-worktree gitfile. The rejection path preserves the stable reason code `canonical_workspace_git_directory_required`.
- The writer resolves and validates the native Codex executable before runtime-policy probing or process execution.
  If the chosen source does not resolve to a native Windows executable, the run stops before `Resolve-StackRuntimePolicy`, before `codex --version`, and before `codex exec`.
- Mutation is read-only by default.
  A mutating prompt must explicitly admit exact repo-relative task-owned paths through `Mutation Admission Path(s)` or `Admitted Changed Path(s)` metadata, or matching explicit command arguments.
- The writer acquires an exclusive lock at `.codex/locks/atlas-workspace-writer.lock.json`.
  The lock receipts owner metadata, blocks contention, preserves stale-lock crash diagnostics, and only releases when the current run still owns the lock file.
- The writer creates the canonical artifact roots before use.
  `.codex/archive`, `.codex/logs`, and `.codex/locks` are created before the run writes receipts, acquires the canonical writer lock, or starts Codex, so prompt archival succeeds even when `.codex/archive` was absent at run start.
- The writer snapshots the initial dirty inventory before execution.
  Each dirty path is receipted with status, digest source, and digest so pre-existing operator-owned dirt can be preserved rather than restaged or recommitted.
- Every admitted task-owned path must start clean.
  If an admitted path is already dirty, the run fails before Codex execution.
- Pre-existing dirt must remain digest-stable.
  Working-tree files keep a streamed SHA-256 file digest, missing tracked files keep their `HEAD` blob identity, and existing dirty directories receive a deterministic `working-tree-directory` fingerprint.
- Nested registered owner worktrees are identity-protected leased resources.
  An untracked directory is classified as `mutable_registered_worktree` only when its `.git` entry is a file, the gitfile target resolves to an existing linked-worktree gitdir, Git resolves the same canonical worktree path, the owner common Git directory is stable, and that owner registration belongs to a nested owner repository rather than the canonical Atlas root.
- Mutable registered owner worktrees may drift internally without blocking the canonical run.
  The writer does not recursively content-hash `mutable_registered_worktree` contents, allows file, index, branch, `HEAD`, and status drift inside that leased owner worktree, and receipts the observation with `contentDriftObserved`.
- Registered-worktree identity drift still fails closed.
  If the linked worktree disappears, the `.git` pointer is deleted or retargeted, the resolved linked-worktree gitdir changes, the owner common Git directory changes, or Git no longer resolves the same registered worktree path, the canonical run fails closed through dirty preservation.
- Directory dirt is fingerprinted recursively and fail-closed.
  The directory fingerprint walks sorted relative entry paths, records each entry path and entry type, streams file contents into the hash without building one giant whole-tree byte array, and fails the run closed if anything inside the pre-existing dirty directory drifts during the task.
- Reparse-point directories are recorded but not descended.
  They contribute a deterministic directory-entry record to the fingerprint, but the writer never traverses through them while preserving dirt.
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
- The receipt also records `codexCommand`.
  The same resolved native executable path is receipted there, passed into `Resolve-StackRuntimePolicy`, and used for process execution so `codex_version` and the executed binary stay aligned.
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

`Directory Dirt Fingerprint`

- When git reports a pre-existing dirty directory entry such as an untracked nested repo boundary, preserve it by a deterministic recursive fingerprint rather than treating the directory like a file path.

`Registered Worktree Lease`

- A nested owner-linked worktree beneath `C:\ATLAS` is preserved by stable registration identity, not by freezing its working contents, because the owner repository remains concurrently mutable outside the canonical writer.

`Registered Worktree Drift Observation`

- Volatile owner-worktree file, status, and `HEAD` changes are observed and receipted with `contentDriftObserved`, but they are not preservation violations unless the registration identity itself drifts.

`Fail-Closed Directory Drift`

- If content, entry type, or entry path changes anywhere inside a pre-existing dirty directory during the run, the canonical writer fails closed even when `git status` still shows the same top-level dirt line.

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
