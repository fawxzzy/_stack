# Fawxzzy Operator Layer

`_stack` is the workspace-level operator folder for local-first workflow commands, shared tasks, receipts scaffolding, and cross-repo operator docs. It is not an app.

## Where to start tasks from
- Start in `C:\Users\zjhre\dev` for workspace orchestration only.
- Start in `C:\Users\zjhre\dev\_stack` for workflow and operator commands.
- Start in each repo root for repo-local coding and implementation work.

## Fitness operator commands
- `pnpm run fitness:doctor`
- `pnpm run fitness:verify`
- `pnpm run fitness:build:vercel`
- `pnpm run fitness:deploy:preview`
- `pnpm run fitness:deploy:preview:logs`
- `pnpm run fitness:deploy:prebuilt`
- `pnpm run fitness:deploy:prod`
- `pnpm run fitness:deploy:prebuilt:prod`

## Fitness deploy model
1. Run `pnpm run fitness:doctor` from `_stack`.
2. Run `pnpm run fitness:verify` from `_stack`.
3. Use `pnpm run fitness:deploy:preview` for the standard preview path.
4. If preview deploy debugging is needed, use `pnpm run fitness:build:vercel` and then `pnpm run fitness:deploy:prebuilt`.
5. Do not run production deploys unless you explicitly intend to promote the current state.

## Scope boundaries
- `_stack` owns workflow commands, editor tasks, receipts scaffolding, and operator docs.
- Fitness is the only repo currently using Vercel.
- Playbook, Lifeline, and Atlas are currently non-Vercel and self-hosted.
- Keep commands manual and explicit; no automatic commit-triggered receipts yet.

## Vercel notes
- Use `pnpm dlx vercel --cwd ../fawxzzy-fitness ...` for Fitness Vercel operations.
- `fitness:build:vercel` uses `vercel build --yes` so the CLI can pull local project settings on the first local Vercel build.
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
