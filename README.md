# Fawxzzy Operator Layer

`_stack` is the workspace-level operator folder for local-first workflow commands, shared tasks, receipts scaffolding, and cross-repo operator docs. It is not an app.

## Where to start tasks from
- Start in the ATLAS root for workspace orchestration only.
- Start in `repos/_stack` for workflow and operator commands.
- Start in each repo root for repo-local coding and implementation work.

## Dispatcher protocol
- The workspace-root dispatcher protocol lives at `docs/dispatcher-protocol.md`.
- Child-task handoff templates live at `templates/child-task-handoff.md`.
- Future automation task drops live at `queue`.
- Fitness verify guidance lives at `docs/fitness-verify.md`.
- Workflow-pack and execution owner-boundary adoption lives at `docs/STACK-ORCHESTRATION-ADOPTION.md`.
- Shared Codex runner guidance lives at `docs/codex-orchestration.md`.

## Shared Codex operator commands
- `pnpm run release:launcher`
- `pnpm run codex:atlas:inbox`
- `pnpm run codex:atlas:inbox:once`
- `pnpm run codex:atlas:task -- -PromptPath C:\path\to\prompt.md`
- `pnpm run codex:atlas-workspace:task -- -PromptPath C:\path\to\prompt.md -CanonicalRootPath C:\ATLAS`
- `pnpm run codex:discordos:inbox`
- `pnpm run codex:discordos:inbox:once`
- `pnpm run codex:discordos:task -- -PromptPath C:\path\to\prompt.md`
- `pnpm run codex:lifeline:inbox`
- `pnpm run codex:lifeline:inbox:once`
- `pnpm run codex:lifeline:task -- -PromptPath C:\path\to\prompt.md`
- `pnpm run codex:playbook:inbox`
- `pnpm run codex:playbook:inbox:once`
- `pnpm run codex:playbook:task -- -PromptPath C:\path\to\prompt.md`
- `pnpm run codex:stack:inbox`
- `pnpm run codex:stack:inbox:once`
- `pnpm run codex:stack:inbox:bootstrap:once`
- `pnpm run codex:stack:task -- -PromptPath C:\path\to\prompt.md`
- `pnpm run codex:stack:task:bootstrap -- -PromptPath C:\path\to\prompt.md`
- `pnpm run codex:stack:verify`
- `pnpm run stack:queue-or-registry:follow-on` packages one bounded retained-state follow-on posture from the authoritative ATLAS execution-transition classifier.
- `pnpm run stack:queue-or-registry:live-direct-json-read-follow-on` rechecks the authoritative ATLAS execution-transition classifier and performs one bounded direct-json read for one admitted retained-state candidate path only.
- `pnpm run stack:queue-or-registry:live-directory-read-follow-on` rechecks the authoritative ATLAS execution-transition classifier and performs one bounded shallow directory read for one admitted retained-state candidate path only.
- `codex:stack:verify` now checks operator surfaces, worker artifacts, and the `_stack` owner-contract adoption map.
- Shared engine scripts live in `ops/codex`.
- Playbook remains the first adapter example through `ops/codex/repos/playbook`.
- Atlas is the first non-Playbook thin adapter through `ops/codex/repos/atlas`.
- Lifeline is the next thin non-Vercel adapter through `ops/codex/repos/lifeline`.
- DiscordOS is a first-class adapter through `ops/codex/repos/discordos`; `_stack` is its execution operator, while DiscordOS remains the single logical canonical board and Discord writer.
- `_stack` is now also a first-class thin adapter through `ops/codex/repos/stack`.
- `_stack` owns the runner; repo-local `.codex/` folders still own inbox, archive, logs, worktrees, and exports.
- `_stack` worker runs stamp `stack_lock_digest` from the root `stack.lock.yaml` and write assignment, status, merge-request, and completion status artifacts alongside the run logs.
- Every governed Codex job now resolves and receipts a runtime-policy envelope before execution using the same precedence chain: explicit command argument, prompt metadata, repo config, then shared defaults.
- Each repo-local `.codex/logs/<run-id>/run.json` now records `runtimePolicy.requested`, `runtimePolicy.resolved`, `runtimePolicy.sources`, `runtimePolicy.codex_version`, `runtimePolicy.warnings`, and `runtimePolicy.blockers` so the effective execution truth is explicit without exposing secrets.
- Each governed repo-task and canonical-workspace run also produces `atlas.component-manifest.v2.json`, `atlas.job-envelope.v2.json`, and `atlas.execution-receipt.v2.json` in its run log. `_stack` invokes the Atlas-owned `packages/atlas-contracts/scripts/validate-artifact.mjs` CLI before Codex and for the terminal receipt; `run.json.atlasContractsV2` retains the artifact paths, CLI results, identities, and state.
- Full local runtime access is capability only. Push, deploy, production, Discord, board, and live-data authority remain denied by default and are recorded separately from the execution facts.
- Atlas stays docs-first and repo-local; push remains manual-only and successful mutating tasks still auto-commit by default.
- `codex:atlas-workspace:task` is a separate `_stack` execution class for the canonical `ATLAS` root. It validates an explicit `ATLAS` directory, does not create a git worktree, defaults to read-only, and requires exact-path mutation admission.
- The canonical workspace writer preserves pre-existing dirt through digest receipts, acquires an exclusive writer lock with stale-lock diagnostics, rejects non-directory `.git` entries with `canonical_workspace_git_directory_required`, stages only exact admitted paths, and keeps push manual-only.
- Canonical workspace writer details live in `docs/canonical-atlas-workspace-writer.md`.
- Lifeline stays repo-local and self-hosted; push remains manual-only and successful mutating tasks still auto-commit by default.
- DiscordOS can only claim a live Discord or board write after production-environment readiness and exact bot-backed readback of the target; host access alone is not Discord, deployment, production, or live-data authority. Vercel production approval remains explicit, current-thread, and per named project.
- `_stack` self-manages through the same runner path with repo-local `_stack\.codex\` artifacts, manual-only push, the same validated commit metadata contract used by the other adapters, and optional local auto-land to local `main` in `ff-only` mode.
- Governed `_stack` jobs now default to the modern `:danger-full-access` permission profile from repo config, while the last accepted bootstrap path remains available through the explicit legacy `danger-full-access` sandbox scripts above.
- Shared base-ref selection is local-first: prefer `origin/main` when it exists locally, otherwise fall back to local `main`, and record the resolved ref in each run manifest.
- Shared auto-commit now uses a validated commit metadata contract via a temporary `.codex/commit-meta.json` artifact, with deterministic fallback messages when Codex output is missing or too generic.
- Shared local landing is adapter-controlled through `localLandingPolicy`; `_stack` is the only repo currently opted into `ff-only`, while Atlas, Playbook, and Lifeline stay disabled by default.

## Release launcher
- `pnpm run release:launcher` starts the config-driven operator launcher in the current terminal.
- `pnpm run atlas:brand:build` regenerates the canonical ATLAS sigil derivatives under `branding/generated`.
- `pnpm run atlas:brand:sync` syncs the generated sigil outputs into `_stack` and any other declared consumers.
- `pnpm run atlas:brand:verify` fails when a declared consumer copy is stale or missing.
- `pnpm run ops:install-shortcut` creates a Desktop shortcut that wraps `ops/Open-ReleaseLauncher.ps1` through `powershell.exe`.
- Use `pnpm run ops:install-shortcut -- -StartMenu` to install the same shortcut into the Start Menu Programs folder instead of the Desktop.
- Use `pnpm run ops:install-shortcut:start-menu` for the pin-to-taskbar path without having to pass flags manually.
- Use `pnpm run ops:install-shortcut:start-menu:terminal` for the same Start Menu shortcut in Windows Terminal mode.
- Use `pnpm run ops:install-shortcut -- -UseWindowsTerminal` to target Windows Terminal when `wt.exe` is available. If it is not available, the installer falls back to `powershell.exe`.
- If `ops/assets/release-launcher.ico` exists, the shortcut installer uses it automatically. Override it with `pnpm run ops:install-shortcut -- -IconPath .\path\to\icon.ico`.
- Approved launcher targets live in `config/release-targets.json`.
- The launcher reads `..\..\docs\LIFELINE_TOPOLOGY_MANIFEST.json` as a read-only contract for Atlas-managed public environments and hostname hints.
- The top-level launcher intentionally exposes operator intents instead of raw scripts: `Preview`, `Deploy Prod`, `Verify`, and `Maintenance / Advanced`.
- `Preview` means the approved preview release target for that app in this repo. It does not mean a local dev server.
- For Atlas-managed apps, the launcher treats the manifest as canonical for public identity. It normalizes service keys to `app/environment`, surfaces hostname hints such as `pr-{number}.fitness.fawxzzy.com`, and fails fast when config contradicts the manifest.
- `Maintenance / Advanced` is where prebuilt deploy variants, log-attached preview flows, and lower-frequency operator commands live.
- The launcher only exposes explicit targets from config; it does not enumerate every `package.json` script.
- Each approved target resolves to an existing `_stack` package script, so the launcher stays a thin control surface instead of becoming a second deploy implementation.
- Launcher execution now flows through a platform-aware command runner: Windows `pnpm` and other `.cmd` / `.bat` wrappers run with shell handling, `powershell` normalizes to `powershell.exe`, and launch failures print resolved `executable`, `args`, `cwd`, and `shell` details.
- Successful preview deploys now end with a compact summary that restates app, environment, hostname hint, detected preview URL, and the standard production counterpart command.
- Production and destructive maintenance targets can require typed confirmation through config.
- Use `node .\scripts\release-launcher.mjs --list` to print the currently approved target IDs.
- Use `node .\scripts\release-launcher.mjs --target <target-id> --dry-run` to inspect a target without executing it.
- Add new launcher entries by extending `config/release-targets.json` with a new approved target that references an existing `_stack` package script and maps it to the correct operator action.
- Atlas-managed apps must not restate incompatible preview/prod availability in `_stack`; non-Atlas-managed apps continue to use `_stack` config as the fallback source of truth until they are brought under the manifest.

## Fitness operator commands
- `pnpm run fitness:doctor`
- `pnpm run fitness:verify`
- `pnpm run fitness:verify:clean`
- `pnpm run fitness:build:vercel`
- `pnpm run fitness:deploy:preview`
- `pnpm run fitness:deploy:preview:logs`
- `pnpm run fitness:deploy:prebuilt`
- `pnpm run fitness:deploy:prod`
- `pnpm run fitness:deploy:prebuilt:prod`

## Mazer operator commands
- `pnpm run mazer:verify`
- `pnpm run mazer:dev`
- `pnpm run mazer:dev:open`
- `pnpm run mazer:preview`
- `pnpm run mazer:preview:open`
- `pnpm run mazer:deploy:preflight`
- `pnpm run mazer:deploy:preview`
- `pnpm run mazer:deploy-preview`
- `pnpm run mazer:deploy:prod`
- `pnpm run mazer:deploy-prod`

## Trove operator commands
- `pnpm run trove:verify`
- `pnpm run trove:deploy:preflight`
- `pnpm run trove:build:vercel`
- `pnpm run trove:deploy:preview`
- `pnpm run trove:deploy:prebuilt`
- `pnpm run trove:deploy:prod`
- `pnpm run trove:deploy:prebuilt:prod`

### Mazer command guide
- Use `pnpm run mazer:dev` to run the repo dev server in the current terminal.
- Use `pnpm run mazer:dev:open` to open a durable `_stack` PowerShell window for the dev server and open the browser at `http://127.0.0.1:5173`.
- Use `pnpm run mazer:preview` to build and run local preview in the current terminal on `http://127.0.0.1:4173`.
- Use `pnpm run mazer:preview:open` to open a durable `_stack` PowerShell window for local preview.
- Use `pnpm run mazer:deploy:preflight` to check the repo Git identity and pinned local Vercel project identity before any Mazer deploy.
- Use either `pnpm run mazer:deploy:preview` or `pnpm run mazer:deploy-preview` for the same preview deploy path.
- Use either `pnpm run mazer:deploy:prod` or `pnpm run mazer:deploy-prod` for the same production deploy path.

### Mazer deploy author preflight
- Mazer deploy wrappers now stop before Vercel if the repo Git identity does not match the required owner identity for private Hobby-team deploys.
- The preflight checks `git config user.name`, `git config user.email`, and the latest commit author on `..\fawxzzy-mazer`.
- This exists because private Hobby-team deploys can fail at Vercel when the latest commit author is not the owner identity. Catching that locally avoids running a deploy that will be rejected upstream.
- Required owner identity: `Zachariah Redfield <zjhredfield@icloud.com>`.
- Fix commands from `_stack`:
  - `git -C "..\fawxzzy-mazer" config user.name "Zachariah Redfield"`
  - `git -C "..\fawxzzy-mazer" config user.email "zjhredfield@icloud.com"`
  - `git -C "..\fawxzzy-mazer" commit --amend --reset-author --no-edit`

### Mazer deploy identity preflight
- Mazer deploy wrappers now also stop before Vercel if `..\fawxzzy-mazer\.vercel\project.json` does not match the pinned canonical project identity in `config/mazer-deploy.identity.json`.
- Required Mazer Vercel identity:
  - `team_CMJn7MvzFZZBnhNnjVUZF2RD`
  - `prj_t3zothbtj9DExrh3FjMsH98hwwSZ`
  - `fawxzzy-mazer`
- This keeps the current author-identity guard and adds immutable local project-link proof before preview or production deploys can proceed.

## Trove deploy model
1. Run `pnpm run trove:deploy:preflight` from `_stack` to validate the pinned local Vercel project identity before any deploy path reaches Vercel.
2. Run `pnpm run trove:verify` from `_stack`.
3. Use `pnpm run trove:deploy:preview` for the standard preview path.
4. If preview deploy debugging is needed, use `pnpm run trove:build:vercel` and then `pnpm run trove:deploy:prebuilt`.
5. Do not run production deploys unless you explicitly intend to promote the current state.

### Desktop shortcut / taskbar pin
- Run `pnpm run ops:install-shortcut` from `_stack` to create `Stack Release Launcher.lnk` on the Desktop.
- Run `pnpm run ops:install-shortcut:start-menu` if you want the shortcut created in Start Menu Programs instead.
- Run `pnpm run ops:install-shortcut -- -UseWindowsTerminal` if you want the shortcut to open inside Windows Terminal when it is installed.
- For the most reliable Windows taskbar pin path, install the Start Menu shortcut and pin that entry from Start.
- The desktop shortcut still works, but the Start Menu shortcut is the preferred pin target.
- This shortcut flow is the supported Windows path for a launcher like this. The installer targets `powershell.exe` and passes the real entrypoint script as arguments instead of creating a second execution path.
- The launcher icon is now a synced consumer copy from the ATLAS branding lane. Do not hand-edit `ops/assets/release-launcher.ico`.
- If the pinned taskbar icon stays stale after reinstalling the shortcut, unpin the old taskbar entry and pin the refreshed Start Menu shortcut again.
- `ops/bin/release-launcher.cmd` remains the direct wrapper for launching the release launcher without installing a shortcut.

### Branding the launcher
- The canonical sigil lives at `branding/source/atlas-sigil-master.png`.
- Generated brand derivatives live at `branding/generated/`.
- `_stack` consumes the generated `core` launcher icon so the shortcut stays aligned with the canonical sigil rather than a console-specific variant.
- The current generated source for that consumer is `branding/generated/ico/atlas-sigil-core-launcher.ico`.
- The synced repo-local consumer copy still lives at `ops/assets/release-launcher.ico`.
- Rebuild with `pnpm run atlas:brand:build` and sync with `pnpm run atlas:brand:sync`.
- After a sync, rerun `pnpm run ops:install-shortcut:start-menu` so Windows writes the current icon path into the shortcut.
- If the taskbar keeps the old cached icon after reinstalling, unpin the old shortcut and pin the refreshed shortcut again.

### Windows Terminal mode
- Use `pnpm run ops:install-shortcut -- -UseWindowsTerminal` for a Windows Terminal shortcut.
- You can combine modes, for example `pnpm run ops:install-shortcut -- -StartMenu -UseWindowsTerminal`.
- If `wt.exe` is unavailable, the installer warns and falls back to `powershell.exe` without changing the launcher entrypoint.

### Other Windows launchers
- `ops/bin/mazer-dev.cmd`
- `ops/bin/mazer-preview.cmd`
- `ops/bin/mazer-deploy-preview.cmd`
- `ops/bin/mazer-deploy-prod.cmd`
- `mazer-dev.cmd` opens the dev server in a durable PowerShell window and then opens the browser at `http://127.0.0.1:5173`.
- The other launchers open separate durable PowerShell windows rooted in `_stack`, so the command keeps running and the window stays available for logs or restart.

## Fitness deploy model
1. Run `pnpm run fitness:doctor` from `_stack`.
2. Run `pnpm run fitness:verify:clean` from `_stack` when you need a fresh-state deploy preflight; the deploy/build wrappers now use this path automatically.
3. Use `pnpm run fitness:deploy:preview` for the standard preview path.
4. If preview deploy debugging is needed, use `pnpm run fitness:build:vercel` and then `pnpm run fitness:deploy:prebuilt`.
5. Do not run production deploys unless you explicitly intend to promote the current state.

## Fitness verify split
- Run `_stack` workflow entrypoints from this repo root.
- Run Fitness lint, test, build, and UI-contract validation from `..\fawxzzy-fitness`.
- Use `docs/fitness-verify.md` for the bottom-action intent consistency checklist.

## Scope boundaries
- `_stack` owns workflow commands, editor tasks, receipts scaffolding, and operator docs.
- `_stack` now also owns the shared Codex inbox/worktree orchestration engine and can self-manage those same operator surfaces through its own thin adapter, but not repo implementation policy.
- `_stack` also owns one canonical Atlas workspace writer surface for tasks that must operate directly against `C:\ATLAS` without creating a worktree.
- Fitness, Mazer, and Trove use Vercel from the local CLI path.
- Playbook, Lifeline, and Atlas are currently non-Vercel and self-hosted. DiscordOS is Vercel-backed but production approval remains current-thread and per project.
- Playbook, Atlas, Lifeline, DiscordOS, and `_stack` are wired as thin shared-runner adapters only; `_stack` still does not add dispatcher-level multi-repo Codex orchestration in this pass.
- Keep commands manual and explicit; no automatic commit-triggered receipts yet.

## Vercel notes
- Use `pnpm dlx vercel --cwd ../fawxzzy-fitness ...` for Fitness Vercel operations.
- Use `pnpm dlx vercel --cwd ../fawxzzy-mazer ...` for Mazer Vercel operations.
- Use `pnpm dlx vercel --cwd ../fawxzzy-trove ...` for Trove Vercel operations.
- `fitness:build:vercel` uses `vercel build --yes` so the CLI can pull local project settings on the first local Vercel build.
- Mazer deploys run the owner-author preflight, verify locally, and then deploy from the local repo path; no GitHub-triggered deploy flow is assumed.
- Mazer deploys now fail closed before Vercel if the local `.vercel/project.json` link does not match the pinned canonical Mazer project identity.
- Trove deploys currently use repo-local verification and the standard Vercel CLI path, but this pass does not perform live project binding.
- Trove deploy wrappers now fail closed before Vercel if `..\fawxzzy-trove\.vercel\project.json` does not match the pinned canonical project identity in `config/trove-deploy.identity.json`.
- Do not use untargeted env listing; use explicit targets:
  - `vercel env ls preview`
  - `vercel env ls production`
- `vercel git connect https://github.com/fawxzzy/fawxzzy-fitness.git` currently fails with `Failed to connect fawxzzy/fawxzzy-fitness to project. Make sure there aren't any typos and that you have access to the repository if it's private.`
- Treat that Fitness Git-connect failure as a GitHub/Vercel auth or access blocker, not as a local `_stack` or `.vercel/project.json` linkage failure; `_stack` preview and prod deploys remain operational through the local Vercel CLI path.

## Receipts
- Operator receipts live in `receipts/`.
- Receipts are for verify, deploy, and operator events only for now.
- Worker lifecycle artifacts live in repo-local `.codex/logs/` for each run, not in receipts.

## Troubleshooting
- If `_stack` scripts are missing, confirm the file is really `package.json`, not `package.json.txt`.
- If a Mazer deploy stops before Vercel, run `pnpm run mazer:deploy:preflight` and apply the printed Git config and amend commands.
- If preview deploy fails after local verify/build succeeds, use the prebuilt path to isolate whether the failure is in remote build versus upload/deploy.
- If a Trove deploy needs remote-build isolation, use the prebuilt Trove path after `pnpm run trove:build:vercel`.
- If preview or prod envs look missing, rerun the targeted doctor command.
