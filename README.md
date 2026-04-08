# Fawxzzy Operator Layer

`_stack` is the workspace-level operator folder for local-first workflow commands, shared tasks, receipts scaffolding, and cross-repo operator docs. It is not an app.

## Where to start tasks from
- Start in `C:\Users\zjhre\dev` for workspace orchestration only.
- Start in `C:\Users\zjhre\dev\_stack` for workflow and operator commands.
- Start in each repo root for repo-local coding and implementation work.

## Dispatcher protocol
- The workspace-root dispatcher protocol lives at `C:\Users\zjhre\dev\_stack\docs\dispatcher-protocol.md`.
- Child-task handoff templates live at `C:\Users\zjhre\dev\_stack\templates\child-task-handoff.md`.
- Lightweight future automation task drops live at `C:\Users\zjhre\dev\_stack\queue`.
- Fitness local verify guidance lives at `C:\Users\zjhre\dev\_stack\docs\fitness-local-verify.md`.
- Shared Codex runner guidance lives at `C:\Users\zjhre\dev\_stack\docs\codex-orchestration.md`.

## Shared Codex operator commands
- `pnpm run codex:atlas:inbox`
- `pnpm run codex:atlas:inbox:once`
- `pnpm run codex:atlas:task -- -PromptPath C:\path\to\prompt.md`
- `pnpm run codex:playbook:inbox`
- `pnpm run codex:playbook:inbox:once`
- `pnpm run codex:playbook:task -- -PromptPath C:\path\to\prompt.md`
- Shared engine scripts live in `C:\Users\zjhre\dev\_stack\ops\codex`.
- Playbook remains the first adapter example through `C:\Users\zjhre\dev\_stack\ops\codex\repos\playbook`.
- Atlas is the first non-Playbook thin adapter through `C:\Users\zjhre\dev\_stack\ops\codex\repos\atlas`.
- `_stack` owns the runner; repo-local `.codex/` folders still own inbox, archive, logs, worktrees, and exports.
- Atlas stays docs-first and repo-local; push remains manual-only and successful mutating tasks still auto-commit by default.

## Fitness operator commands
- `pnpm run fitness:doctor`
- `pnpm run fitness:verify`
- `pnpm run fitness:build:vercel`
- `pnpm run fitness:deploy:preview`
- `pnpm run fitness:deploy:preview:logs`
- `pnpm run fitness:deploy:prebuilt`
- `pnpm run fitness:deploy:prod`
- `pnpm run fitness:deploy:prebuilt:prod`

## Mazer operator commands
- `pnpm run mazer:verify`
- `pnpm run mazer:dev`
- `pnpm run mazer:preview`
- `pnpm run mazer:deploy:preview`
- `pnpm run mazer:deploy:prod`

### Windows launchers to pin
- `C:\Users\zjhre\dev\_stack\ops\bin\mazer-dev.cmd`
- `C:\Users\zjhre\dev\_stack\ops\bin\mazer-preview.cmd`
- `C:\Users\zjhre\dev\_stack\ops\bin\mazer-deploy-preview.cmd`
- `C:\Users\zjhre\dev\_stack\ops\bin\mazer-deploy-prod.cmd`
- Each launcher opens a separate durable PowerShell window rooted in `_stack`, so the command keeps running and the window stays available for logs or restart.

## Fitness deploy model
1. Run `pnpm run fitness:doctor` from `_stack`.
2. Run `pnpm run fitness:verify` from `_stack`.
3. Use `pnpm run fitness:deploy:preview` for the standard preview path.
4. If preview deploy debugging is needed, use `pnpm run fitness:build:vercel` and then `pnpm run fitness:deploy:prebuilt`.
5. Do not run production deploys unless you explicitly intend to promote the current state.

## Fitness local verify split
- Run `_stack` workflow entrypoints from `C:\Users\zjhre\dev\_stack`.
- Run Fitness lint, test, build, and UI-contract validation from `C:\Users\zjhre\dev\fawxzzy-fitness`.
- Use `C:\Users\zjhre\dev\_stack\docs\fitness-local-verify.md` for the bottom-action intent consistency checklist.

## Scope boundaries
- `_stack` owns workflow commands, editor tasks, receipts scaffolding, and operator docs.
- `_stack` now also owns the shared Codex inbox/worktree orchestration engine, but not repo implementation policy.
- Fitness and Mazer currently use Vercel from the local CLI path.
- Playbook, Lifeline, and Atlas are currently non-Vercel and self-hosted.
- Atlas is wired as a thin shared-runner adapter only; `_stack` still does not add dispatcher-level multi-repo Codex orchestration in this pass.
- Keep commands manual and explicit; no automatic commit-triggered receipts yet.

## Vercel notes
- Use `pnpm dlx vercel --cwd ../fawxzzy-fitness ...` for Fitness Vercel operations.
- Use `pnpm dlx vercel --cwd ../fawxzzy-mazer ...` for Mazer Vercel operations.
- `fitness:build:vercel` uses `vercel build --yes` so the CLI can pull local project settings on the first local Vercel build.
- Mazer deploys verify locally first and then deploy from the local repo path; no GitHub-triggered deploy flow is assumed.
- Do not use untargeted env listing; use explicit targets:
  - `vercel env ls preview`
  - `vercel env ls production`
- Vercel Git is intentionally disconnected for the current local-first deploy path.

## Receipts
- Operator receipts live in `C:\Users\zjhre\dev\_stack\receipts`.
- Receipts are for verify, deploy, and operator events only for now.

## Troubleshooting
- If `_stack` scripts are missing, confirm the file is really `package.json`, not `package.json.txt`.
- If preview deploy fails after local verify/build succeeds, use the prebuilt path to isolate whether the failure is in remote build versus upload/deploy.
- If preview or prod envs look missing, rerun the targeted doctor command.
