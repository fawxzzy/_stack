# Queue Pattern

`C:\Users\zjhre\dev\_stack\queue` is a lightweight task-drop area for future automation and wrapper scripts. It is intentionally simple and manual.

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
Working Directory: C:\Users\zjhre\dev\fawxzzy-fitness
Allowed Edit Surface:
- C:\Users\zjhre\dev\fawxzzy-fitness\**
```

Then include:

- objective
- context
- constraints
- verification
- deliver-back expectations

The payload should stay self-contained so later automation can ingest it without reading unrelated workspace files.
