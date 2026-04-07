# _stack Rules

Scope
- Applies only inside `C:\Users\zjhre\dev\_stack`.
- Inherit workspace rules from `C:\Users\zjhre\dev\AGENTS.md` unless a rule here is narrower.

Purpose
- `_stack` is the operator layer for the `dev` workspace.
- Keep this folder focused on workflow commands, editor tasks, receipts scaffolding, and cross-repo operator docs.
- Do not turn `_stack` into an app or a second implementation surface.

Execution
- Run workflow commands from `_stack`.
- Prefer existing `package.json` scripts and `.vscode` tasks over ad hoc commands.
- Keep Vercel logic Fitness-specific unless the workspace manifest is intentionally expanded later.

Editing Boundaries
- Do not edit repo implementation code from `_stack` work unless a tiny workflow-facing change is strictly required and explicitly in scope.
- Keep cross-repo changes limited to named operator surfaces.
- Do not add automatic commit-triggered receipts unless explicitly requested.

Receipts
- Store verify, deploy, and operator-event receipts in `C:\Users\zjhre\dev\_stack\receipts`.
- Keep receipts lightweight and manual for now.
