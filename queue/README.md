# Queue Pattern

`queue/` is a lightweight task-drop area for future automation and wrapper scripts. It is intentionally simple and manual.

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
