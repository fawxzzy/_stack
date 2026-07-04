# Fitness Discord Feedback Worker Governed Poll Surface Runtime Proof - 2026-06-18

- Date: `2026-06-18`
- Repo: `_stack`
- Scope: `governed Fitness Discord feedback worker runtime proof`

## What changed

- `_stack` now owns a machine-readable worker control surface:
  - `pnpm run fitness:discord:worker:start`
  - `pnpm run fitness:discord:worker:stop`
  - `pnpm run fitness:discord:worker:status`
  - `pnpm run fitness:discord:worker:restart`
- Fitness production was redeployed through the governed `_stack` path:
  - deployment id: `dpl_ASjZSfbYtRL1DVSU2b6qMRGVwFfh`
  - production url: `https://fawxzzy-fitness-k17ncu8x0-fawxzzy.vercel.app`
  - canonical alias: `https://fawxzzy-fitness-local.vercel.app`

## Runtime proof

### Production route proof

- `GET https://fawxzzy-fitness-local.vercel.app/api/discord/message-commands/poll`
  - returned `401 Unauthorized`
  - matched path: `/api/discord/message-commands/poll`
- `GET https://fawxzzy-fitness-local.vercel.app/api/discord/interactions`
  - returned `401 Unauthorized`
  - matched path: `/api/discord/interactions`

This proves the dedicated poll route is live on the canonical production alias as an API surface rather than falling through to login.

### Worker resolution proof

- canonical worker env lane:
  - `secrets/local/fawxzzy-fitness-discord-worker.env`
- resolved default poll url from that env lane:
  - `https://fawxzzy-fitness-local.vercel.app/api/discord/message-commands/poll`

### Worker start proof

`pnpm run fitness:discord:worker:status` now reports:

- `repoPath: repos/fawxzzy-fitness`
- `envPath: secrets/local/fawxzzy-fitness-discord-worker.env`
- `running: true`
- startup log includes:
  - `loaded env file ... fawxzzy-fitness-discord-worker.env`
  - `gateway socket open`
  - `gateway ready`
  - `feedback setup poll completed { reason: 'startup', messageId: null, processed: [] }`
- stderr tail is empty

## Consequence

The dedicated Fitness poll surface is no longer only owner-code truth.

It is now:

- deployed on the canonical alias
- selected by the canonical worker env lane
- consumed by the governed worker control surface
- proven live through a successful startup poll

That converts the remaining blocker from route-shape ambiguity into one explicit retained seam.
