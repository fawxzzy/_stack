# Dispatcher Protocol

## Purpose

`C:\Users\zjhre\dev` is a dispatcher-only orchestration layer for the local-first workspace. It routes work, records operator context, and delegates repo mutations to the correct execution surface. It is not a universal editor.

`C:\Users\zjhre\dev\_stack` remains the operator layer for shared workflow commands, receipts, queue drops, runbooks, and dispatcher templates.

## Task Classes

### 1. workspace-orchestration

Use for workspace-wide routing, operator policy, manifests, dispatcher docs, queue drops, templates, and receipts.

- Allowed edit surface:
  - `C:\Users\zjhre\dev\AGENTS.md`
  - `C:\Users\zjhre\dev\_stack\**`
- Typical outputs:
  - routing rules
  - manifests
  - runbooks
  - queue items
  - receipts

### 2. operator-workflow

Use for workflow commands and shared operator tooling executed from `_stack`.

- Primary execution surface:
  - `C:\Users\zjhre\dev\_stack`
- Typical actions:
  - `doctor`
  - `heal`
  - `route`
  - `verify`
  - `deploy`
- Constraint:
  - Prefer `_stack/package.json` scripts and `_stack/.vscode/tasks.json` tasks before inventing ad hoc workspace commands.

### 3. repo-local

Use for application code, tests, config, migrations, content, or repo-specific docs that belong to exactly one repo.

- Execution surface:
  - the target repo root only
- Mutation rule:
  - repo code changes must be performed by a repo-local runner inside that repo
- Current named repos:
  - `fitness` -> `C:\Users\zjhre\dev\fawxzzy-fitness`
  - `playbook` -> `C:\Users\zjhre\dev\fawxzzy-playbook`
  - `lifeline` -> `C:\Users\zjhre\dev\fawxzzy-lifeline`
  - `atlas` -> `C:\Users\zjhre\dev\fawxzzy-atlas`

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

1. Start at `C:\Users\zjhre\dev` only to classify work, route child tasks, and update dispatcher/operator artifacts.
2. The root runner may edit only:
   - `C:\Users\zjhre\dev\AGENTS.md`
   - `C:\Users\zjhre\dev\_stack\**`
3. Any app or repo implementation change must be handed off to a repo-local runner in the target repo.
4. `_stack` is the declared execution surface for shared `doctor`, `heal`, `route`, `verify`, and `deploy` actions.
5. Fitness is the only repo currently using Vercel.
6. Playbook, Lifeline, and Atlas are currently self-hosted and should not be routed through Vercel workflows.
7. Cross-repo work should produce thin orchestration artifacts in `_stack` and keep repo mutations delegated.
8. Do not restructure sibling repos from the dispatcher layer.

## Dispatcher Decision Table

| Task pattern | Class | Owner surface | Notes |
| --- | --- | --- | --- |
| Update workspace rules, manifests, runbooks, queue items, receipts | workspace-orchestration | `dev/` root plus `_stack` | No repo code edits |
| Run shared verify/deploy/doctor workflows | operator-workflow | `_stack` | Prefer existing `_stack` tasks/scripts |
| Change a single app, config, or test in one repo | repo-local | target repo | Root runner hands off |
| Coordinate named changes across multiple repos | cross-repo | `_stack` plus named repos | Use child tasks per repo |

## Child Task Handoff

Use the handoff template at `C:\Users\zjhre\dev\_stack\templates\child-task-handoff.md` when the dispatcher needs to delegate to `_stack`, Fitness, Playbook, Lifeline, or Atlas.

The parent runner should include:

- task class
- target repo or `_stack`
- absolute working directory
- allowed edit surface
- objective
- constraints
- verification command or explicit verification expectation
- deliverables back to the parent runner

## Queue / Task Drop Pattern

Use `C:\Users\zjhre\dev\_stack\queue` as a lightweight future automation boundary.

- `pending/`
  - new task drops from the dispatcher
- `claimed/`
  - optional claim/move marker for an active worker
- `done/`
  - completed task records or archived drops

Task drops should be small, explicit, and easy for a wrapper script or automation to pick up later. Prefer one file per task and keep the payload self-contained.
