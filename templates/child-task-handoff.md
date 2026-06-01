# Child Task Handoff Template

Use this template when the `dev/` root dispatcher hands work to `_stack` or a repo-local runner.

## Generic Template

```md
Task Class: <workspace-orchestration | operator-workflow | repo-local | cross-repo>
Target: <_stack | fitness | playbook | lifeline | atlas>
Working Directory: <ATLAS-relative or repo-relative path>
Allowed Edit Surface:
- <ATLAS-relative or repo-relative path or glob>
Stack Lock Digest: <sha256 digest from stack.lock.yaml>
Worker Assignment Id: <assignment id>
Worker Id: <worker id>
Input Handoff Refs:
- <handoff ref>

Objective:
<single concrete outcome>

Context:
- <relevant manifest or workflow note>
- <repo/deploy model note if needed>

Constraints:
- Preserve the local-first workflow model.
- Do not edit files outside the allowed surface.
- Use `_stack` workflow commands when they exist.
- Do not create opportunistic repo changes.

Acceptance Criteria:
- For mutating tasks, list one individually checkable criterion per bullet.
- Use stable criterion wording that can be proven from the final repo diff.
- Do not claim success for any criterion that cannot be proven from the final diff.

Expected Changed Paths:
- For mutating tasks, list the repo-relative paths or globs that are expected to change.

Expected Unchanged Paths:
- For mutating tasks, list the repo-relative paths or globs that must stay unchanged unless explicitly justified.

Blocked / Skipped Reporting Rules:
- If a criterion cannot be completed, the worker must mark it as `blocked`, `skipped`, or `failed` instead of `satisfied`.
- If an expected unchanged path must change, the worker must provide an explicit justification.
- Partial completion must be reported as partial; do not summarize it as success.

Verification:
- <command to run, or "report no repo-local verify command exists for this task">
Pause / Resume / Merge:
- If the worker is resuming or merging, include the paused handoff refs and any merge-request ref in the prompt metadata.
- Use touched ranges from status artifacts, not transcripts, as the collision observation surface.

Deliver Back:
- Summary of changes
- Files changed
- Verification result
- Risks or follow-ups
- Criterion-by-criterion completion status for mutating tasks
```

## Target Presets

### `_stack`

```md
Task Class: operator-workflow
Target: _stack
Working Directory: repos/_stack
Allowed Edit Surface:
- repos/_stack/**

Context:
- `_stack` is the operator layer for workflow commands, receipts, tasks, queue drops, and shared runbooks.
- `_stack` worker prompts should carry the current stack lock digest so assignments remain pinned to one working set.
```

### Fitness

```md
Task Class: repo-local
Target: fitness
Working Directory: repos/fawxzzy-fitness
Allowed Edit Surface:
- repos/fawxzzy-fitness/**

Context:
- Fitness is the only repo currently using Vercel.
- Prefer `_stack` for shared doctor/verify/deploy workflow commands.
```

### Playbook

```md
Task Class: repo-local
Target: playbook
Working Directory: repos/fawxzzy-playbook
Allowed Edit Surface:
- repos/fawxzzy-playbook/**

Context:
- Playbook is currently self-hosted and not using Vercel.
```

### Lifeline

```md
Task Class: repo-local
Target: lifeline
Working Directory: repos/fawxzzy-lifeline
Allowed Edit Surface:
- repos/fawxzzy-lifeline/**

Context:
- Lifeline is currently self-hosted and not using Vercel.
```

### Atlas

```md
Task Class: repo-local
Target: atlas
Working Directory: .
Allowed Edit Surface:
- docs/**
- ops/**
- schemas/**
- tests/**
- README-STACK.md
- stack.yaml

Context:
- Atlas is currently self-hosted and not using Vercel.
```
