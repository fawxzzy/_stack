Make one trivial docs-only wording improvement in `README.md` to prove the `_stack` self-adapter path end to end.

Requirements:
- Change only `README.md`.
- Keep the change tiny and safe.
- Improve wording only; do not change behavior.
- Do not touch sibling repos.
- Do not push.

Verification:
- Run the adapter default verification commands.
- Archive this prompt and write run logs.

Implementation target:
- Prefer changing a single phrase in `README.md` for clarity. A good candidate is changing `Fitness local verify guidance` to `Fitness local verification guidance`.

Commit metadata contract:
- If you make repository changes that should be committed, write UTF-8 JSON to .codex/commit-meta.json.
- Use exactly this shape: {"type":"<type>","scope":"<scope>","summary":"<summary>"}
- Allowed commit types: feat, fix, docs, refactor, test, chore.
- Scope must be a short lowercase slug using letters, digits, and hyphens.
- Summary must be specific, contain at least two words, and must not be generic like update, done, fixes, or misc changes.
- If you make no repository changes, do not create the commit metadata artifact.
- The runner will consume and remove the artifact before staging.
- Do not push. Push remains manual-only.