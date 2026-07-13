# _stack Rules

Scope
- Applies only inside this repo.
- Inherit workspace rules from the ATLAS root `AGENTS.md` unless a rule here is narrower.

Purpose
- `_stack` is the operator layer for the `dev` workspace.
- Keep this folder focused on workflow commands, editor tasks, receipts scaffolding, and cross-repo operator docs.
- Do not turn `_stack` into an app or a second implementation surface.

Execution
- Run workflow commands from `_stack`.
- Prefer existing `package.json` scripts and `.vscode` tasks over ad hoc commands.
- Keep Vercel logic Fitness-specific unless the workspace manifest is intentionally expanded later.
- Governed Codex jobs must resolve runtime policy with this precedence: explicit command argument, prompt metadata, repo config, then shared defaults.
- Governed Codex jobs must receipt their effective runtime-policy envelope in repo-local `.codex/logs/<run-id>/run.json` before execution begins.
- Codex workers may edit admitted files but must not stage, commit, amend, merge, rebase, reset, switch branches, or move Git refs. `_stack` owns Git state transitions after verification.
- If a worker moves its task HEAD, canonical HEAD, or landing ref, fail closed as `worker_git_state_failed` and preserve `worker_git_head_mutation_detected` in `run.json`.
- Treat `codex:atlas-workspace:task` as a distinct `_stack` execution class for the canonical `C:\ATLAS` root. It must not create a git worktree.
- The canonical Atlas workspace writer stays read-only unless the prompt or explicit command arguments admit exact repo-relative task-owned paths.
- Canonical workspace runs must preserve pre-existing dirt, acquire the writer lock, stage only exact admitted paths, and keep push manual-only.

Editing Boundaries
- Do not edit repo implementation code from `_stack` work unless a tiny workflow-facing change is strictly required and explicitly in scope.
- Keep cross-repo changes limited to named operator surfaces.
- Do not add automatic commit-triggered receipts unless explicitly requested.

Receipts
- Store verify, deploy, and operator-event receipts in `receipts/`.
- Keep receipts lightweight and manual for now.
