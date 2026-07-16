# Queue Pattern

`queue/` is a lightweight task-drop area for future automation and wrapper scripts. It is intentionally simple and manual.

`owner-work-registry.json` is the machine-readable owner admission source for the `_stack` project board. An empty registry with `state: ready-empty` is authoritative, while an active registry contains only explicitly owner-admitted work. Atlas candidates must not be copied into that registry or the board without an explicit `_stack` ownership decision.

## Layout

- `pending/`
  - dispatcher drops a new task file here
- `claimed/`
  - optional move target for the active worker or wrapper
- `done/`
  - completed task records or archived drops

## Drop Format

Use one Markdown file per task. Suggested filename:

`YYYYMMDD-HHMMSS-target-short-name.md`

Suggested front matter:

```md
Task Class: repo-local
Target: fitness
Working Directory: repos/fawxzzy-fitness
Allowed Edit Surface:
- repos/fawxzzy-fitness/**
```

Then include:

- objective
- context
- constraints
- acceptance criteria for mutating tasks
- expected changed paths for mutating tasks
- expected unchanged paths for mutating tasks
- blocked / skipped reporting rules for mutating tasks
- verification
- deliver-back expectations
- stack lock digest
- worker assignment/status or merge-request refs when the task is a pause, resume, or merge step

The payload should stay self-contained so later automation can ingest it without reading unrelated workspace files.

Rules:

- mutating Codex tasks are not considered governed unless they declare explicit acceptance criteria
- acceptance criteria should be individually checkable and phrased so the worker can prove them from the final diff
- mutating prompts should name the expected changed and unchanged paths when that is knowable up front
- if a mutating criterion cannot be completed or proven, the worker must report it as blocked, skipped, or failed rather than claiming success
- exploratory or non-mutating prompts may omit the mutating-task sections when the task is intentionally analysis-only
- the deterministic board export at `exports/stack.project-board.owner-export.v1.json` contains only records admitted through `owner-work-registry.json`; `pending/`, `claimed/`, and Atlas proposals do not implicitly become board cards
- scheduled `.codex/inbox` prompts use the separate `atlas.stack.inbox.v1` admission contract documented in `docs/codex-orchestration.md`; they do not create a second owner queue
