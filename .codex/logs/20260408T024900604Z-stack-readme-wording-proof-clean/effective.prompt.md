Make one tiny docs-only wording improvement in `README.md` and nothing else.

Exact change:
- In the existing dispatcher protocol bullet, replace `Fitness local verify guidance lives at ` with `Fitness local verification guidance lives at `.

Hard boundaries:
- Edit only `README.md`.
- Do not create, edit, or stage any files under `.codex/`, `receipts/`, or any other path.
- Do not create extra summaries, receipts, archives, or logs in the repository. The runner handles those artifacts automatically.
- Do not touch sibling repos.
- Do not push.

Keep the change tiny and safe.

Commit metadata contract:
- If you make repository changes that should be committed, write UTF-8 JSON to .codex/commit-meta.json.
- Use exactly this shape: {"type":"<type>","scope":"<scope>","summary":"<summary>"}
- Allowed commit types: feat, fix, docs, refactor, test, chore.
- Scope must be a short lowercase slug using letters, digits, and hyphens.
- Summary must be specific, contain at least two words, and must not be generic like update, done, fixes, or misc changes.
- If you make no repository changes, do not create the commit metadata artifact.
- The runner will consume and remove the artifact before staging.
- Do not push. Push remains manual-only.