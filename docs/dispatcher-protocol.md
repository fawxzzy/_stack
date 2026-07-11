# Dispatcher Protocol

## Purpose

The ATLAS root is a dispatcher-only orchestration layer for the local-first workspace. It routes work, records operator context, and delegates repo mutations to the correct execution surface. It is not a universal editor.

`repos/_stack` remains the operator layer for shared workflow commands, receipts, queue drops, runbooks, and dispatcher templates.

## Task Classes

### 1. workspace-orchestration

Use for workspace-wide routing, operator policy, manifests, dispatcher docs, queue drops, templates, and receipts.

- Allowed edit surface:
- `AGENTS.md`
- `repos/_stack/**`
- Typical outputs:
  - routing rules
  - manifests
  - runbooks
  - queue items
  - receipts

### 2. operator-workflow

Use for workflow commands and shared operator tooling executed from `_stack`.

- Primary execution surface:
- `repos/_stack`
- Typical actions:
  - `doctor`
  - `heal`
  - `route`
  - `verify`
  - `deploy`
  - shared Codex inbox and task runs for `_stack` operator surfaces
- Constraint:
  - Prefer `_stack/package.json` scripts and `_stack/.vscode/tasks.json` tasks before inventing ad hoc workspace commands.

### 3. repo-local

Use for application code, tests, config, migrations, content, or repo-specific docs that belong to exactly one repo.

- Execution surface:
  - the target repo root only
- Mutation rule:
  - repo code changes must be performed by a repo-local runner inside that repo
- Current named repos:
  - `fitness` -> `repos/fawxzzy-fitness`
  - `mazer` -> `repos/fawxzzy-mazer`
  - `trove` -> `repos/fawxzzy-trove`
  - `playbook` -> `repos/fawxzzy-playbook`
  - `lifeline` -> `repos/fawxzzy-lifeline`
- `atlas` -> `.` (ATLAS root coordination layer)

### 4. cross-repo

Use only when the task explicitly spans more than one repo and coordination is required.

- Allowed scope:
  - only the named repos in the task
  - plus `_stack` when orchestration artifacts are needed
- Mutation rule:
  - split work into repo-local child tasks whenever possible
- Constraint:
  - do not turn the workspace root into a broad mutation surface

## Routing Rules

1. Start at the ATLAS root only to classify work, route child tasks, and update dispatcher/operator artifacts.
2. The root runner may edit only:
- `AGENTS.md`
- `repos/_stack/**`
3. Any app or repo implementation change must be handed off to a repo-local runner in the target repo.
4. `_stack` is the declared execution surface for shared `doctor`, `heal`, `route`, `verify`, and `deploy` actions.
5. `_stack` may also self-manage `_stack`-only workflow changes through its thin shared-runner adapter; this does not widen `_stack` into a dev-root multi-repo dispatcher.
6. `_stack` may optionally fast-forward successful shared-runner task commits back onto local `_stack` `main` when its adapter enables `ff-only`; this remains local-only and does not permit auto-push.
7. Shared runner base-ref resolution stays local-first: prefer `origin/main` when it exists locally, otherwise use local `main`, and record the resolved ref in the run manifest.
8. Governed Codex jobs must resolve and receipt one runtime-policy envelope before execution; precedence is explicit command argument, prompt metadata, repo config, then shared defaults.
9. Runtime-policy receipts must record requested versus effective settings plus `codex_version`, `warnings`, and `blockers` so hidden model, speed, or permission drift is observable in the run manifest.
10. Fitness, Mazer, and Trove currently use Vercel.
11. Playbook, Lifeline, and Atlas are currently self-hosted and should not be routed through Vercel workflows.
12. Cross-repo work should produce thin orchestration artifacts in `_stack` and keep repo mutations delegated.
13. Do not restructure sibling repos from the dispatcher layer.

## Dispatcher Decision Table

| Task pattern | Class | Owner surface | Notes |
| --- | --- | --- | --- |
| Update workspace rules, manifests, runbooks, queue items, receipts | workspace-orchestration | `dev/` root plus `_stack` | No repo code edits |
| Run shared verify/deploy/doctor workflows | operator-workflow | `_stack` | Prefer existing `_stack` tasks/scripts |
| Change a single app, config, or test in one repo | repo-local | target repo | Root runner hands off |
| Coordinate named changes across multiple repos | cross-repo | `_stack` plus named repos | Use child tasks per repo |

## Child Task Handoff

Use the handoff template at `templates/child-task-handoff.md` when the dispatcher needs to delegate to `_stack`, Fitness, Playbook, Lifeline, or Atlas.

The parent runner should include:

- task class
- target repo or `_stack`
- absolute working directory
- allowed edit surface
- stack lock digest
- runtime policy metadata when the child task must pin model, speed, permissions, approval, or web-search behavior explicitly
- worker assignment/status or merge-request refs when the handoff is a resume or merge step
- objective
- constraints
- acceptance criteria, expected changed paths, expected unchanged paths, and blocked/skipped reporting rules for mutating tasks
- verification command or explicit verification expectation
- deliverables back to the parent runner

Rule:

- mutating child-task handoffs are not governed unless they declare the acceptance-criteria contract from `templates/child-task-handoff.md`

## Queue / Task Drop Pattern

Use `queue` as a lightweight future automation boundary.

- `pending/`
  - new task drops from the dispatcher
- `claimed/`
  - optional claim/move marker for an active worker
- `done/`
  - completed task records or archived drops

Task drops should be small, explicit, and easy for a wrapper script or automation to pick up later. Prefer one file per task and keep the payload self-contained.
When the task drop is for `_stack`, include the current `stack_lock_digest` and any paused handoff refs so the worker artifacts stay tied to the same pinned working set.
