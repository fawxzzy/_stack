Make one tiny docs-only wording improvement in `README.md` and nothing else.

Exact change:
- Replace `Fitness local verify guidance lives at ` with `Fitness local verification guidance lives at ` in the existing dispatcher protocol bullet.

Requirements:
- Change only `README.md`.
- Keep the change tiny and safe.
- Do not touch sibling repos.
- Do not push.

Verification:
- Run the adapter default verification commands.
- Archive this prompt and write run logs.

Commit metadata:
- If you change the file, write valid commit metadata for a docs-only README wording clarification.

Commit metadata contract:
- If you make repository changes that should be committed, write UTF-8 JSON to .codex/commit-meta.json.
- Use exactly this shape: {"type":"<type>","scope":"<scope>","summary":"<summary>"}
- Allowed commit types: feat, fix, docs, refactor, test, chore.
- Scope must be a short lowercase slug using letters, digits, and hyphens.
- Summary must be specific, contain at least two words, and must not be generic like update, done, fixes, or misc changes.
- If you make no repository changes, do not create the commit metadata artifact.
- The runner will consume and remove the artifact before staging.
- Do not push. Push remains manual-only.