# Jen Hermes migration runbook

Owner: Moss  
Target: migrate Jen from OpenClaw to Hermes-native container with Todoist, gog/Calendar, cron, and Telegram cutover.

## Global constraints

- No bulk memory/session import from OpenClaw.
- No secrets in git. Secrets/state live under ignored `runtime/jen-home` or host-private `.env` only.
- Commit after each migration step.
- Fresh review after each step before moving on.
- Prefer live validation over configuration assumptions.

## Step 1 — Jen container scaffold, no live external writes

### Execution plan

1. Add `jen` as a Hermes service using a dedicated image, runtime home, public contract mount, private workspace mount, and shared handoff mount.
2. Create public-safe Jen identity/contract material sufficient for Hermes startup without importing raw OpenClaw memory/sessions.
3. Materialize ignored runtime home from Moss model/auth baseline, replacing identity files with Jen-specific `SOUL.md`, `AGENTS.md`, and README.
4. Keep Telegram cutover and Todoist/Calendar writes disabled until later steps. In the Jen runtime home, Telegram environment variables must remain commented with STEP1_GUARD_DISABLED_UNTIL_TELEGRAM_CUTOVER until Step 7.

### Review gates

- Gate 1A — Compose/mount gate: `docker compose config --services` includes `jen`; rendered service has `/opt/data`, `/agents/jen/public`, `/agents/jen/private`, and `/mnt/hermes-shared` mounts; no Docker socket or broad host mount.
- Gate 1B — Identity/scope gate: Jen docs state productivity ownership and explicitly exclude Moss infrastructure ownership.
- Gate 1C — Runtime smoke gate: `docker compose --profile jen-bootstrap up -d --build jen` starts a healthy container and `hermes status --all` runs inside it without using Telegram/live writes.

## Step 2 — gog install and persistent state

### Execution plan

1. Install `gog` v0.19.0 in Jen image from the official `openclaw/gogcli` GitHub release, verifying the release checksum before installing `/usr/local/bin/gog`.
2. Set `GOG_HOME=/opt/data/gog`, `GOG_KEYRING_BACKEND=file`, and keep `GOG_KEYRING_PASSWORD` private/unset until credential provisioning. Runtime state must be created under Jen's ignored `/opt/data/gog` bind mount.
3. Validate `gog --version`, `gog auth keyring`, and `gog auth doctor --check` from the Jen container as the Hermes runtime user (uid 99:100). Before credentials exist, `auth doctor --check` must fail closed rather than silently claiming Calendar readiness.

### Review gates

- Gate 2A — Binary provenance gate: image build records install source/version, verifies `checksums.txt`, and does not curl or bake secrets.
- Gate 2B — State gate: gog environment points at `/opt/data/gog`, not public scaffold or image layer; `GOG_KEYRING_PASSWORD` is absent until private auth provisioning.
- Gate 2C — Auth-health gate: unauthenticated state fails closed; after credentials are provisioned, the same container entrypoint must pass `gog auth doctor --check`.

## Step 3 — Calendar wrappers read-only first

### Execution plan

1. Add Jen Calendar wrappers under `agents/public/jen/tools/wrappers/` around `gog`: `jen-calendar-runtime` for `health`, `list-events`, `freebusy`, and `get-event`; `jen-calendar-capture` remains write-blocked until mutation gateway work.
2. Require explicit RFC3339 `--from` and `--to` values plus explicit `--calendar` for read commands. Normalize handled outcomes into `jen-calendar-runtime.v1` JSON rather than raw provider passthrough.
3. Add a fake-gog contract smoke test and validate the live unauthenticated container path records `auth_failure` instead of claiming readiness.

### Review gates

- Gate 3A — Read-only gate: Step 3 wrappers expose only read/health paths; `capture-event`, `set-reminders`, and `delete-event` return `failure_class:"unavailable"` until mutation/idempotency safety is wired.
- Gate 3B — Timezone gate: range reads require explicit caller-provided RFC3339 timestamps with timezone; no wrapper accepts implicit local-date mutation shortcuts.
- Gate 3C — Live-read gate: authenticated Jen container can list today/range events, or unauthenticated container records a clear `auth_failure` blocker through the same wrapper path.

## Step 4 — Todoist MCP official integration

### Execution plan

1. Configure the official Doist hosted MCP endpoint for Jen in Jen's private Hermes runtime config only: `https://ai.todoist.net/mcp`.
2. Prefer direct HTTP OAuth. In the current headless container, OAuth generated a valid browser URL but could not complete the callback before timeout, so Step 4 uses the official endpoint with a private `Authorization: Bearer ...` header sourced from Jen's ignored Todoist runtime token.
3. Test MCP discovery from inside the Jen container without granting raw MCP write authority to normal Jen behavior yet. The official MCP exposes both read and write tools; writes remain policy-blocked until Step 5 wrappers/mutation gateway pass.

### Review gates

- Gate 4A — MCP config gate: config is Jen-local under ignored `runtime/jen-home/config.yaml`, not Moss global; no token is committed or written to public scaffold.
- Gate 4B — Discovery gate: `hermes mcp test todoist` from `the-ai-crowd-jen-1` connects to `https://ai.todoist.net/mcp` and discovers Todoist MCP tools.
- Gate 4C — Safety gate: Jen instructions still route mutations through Jen task runtime/mutation gateway; Step 4 is transport/discovery only, not live write authority.

### Validation notes

- OAuth attempt: Hermes started Todoist OAuth, generated the Todoist authorization URL, then timed out in the headless container before callback completion and did not persist config.
- Token fallback: Jen's OpenClaw Todoist token was copied into ignored `runtime/jen-home/.env` without printing the value; a quoting issue in the first copy preserved shell quotes and produced REST/MCP 401s, then was corrected by sourcing the OpenClaw env and rewriting the private value unquoted.
- REST credential check: Todoist REST `/api/v1/projects` returned a project count from the Jen container with the private token.
- MCP check: `hermes mcp test todoist` connected to the official endpoint and discovered 50 tools.

## Step 5 — Todoist runtime and mutation/idempotency safety

### Execution plan

1. Port/adapt the OpenClaw Jen Todoist runtime into the Hermes public scaffold: `jen-task-runtime`, `jen-task-read`, `jen-todoist-capture`, Todoist REST transport, mutation gateway, runtime helper, write-safety gate, and SQLite idempotency store.
2. Move runtime defaults off the public read-only scaffold and into ignored Jen runtime state: `/opt/data/.env` for the token, `/opt/data/state/jen/...` for heartbeat/observation/idempotency data.
3. Validate read-only task listing first, then run one explicit reversible live smoke mutation through `jen-todoist-capture`; replay the same request and verify it returns the same external task id rather than creating a duplicate; then complete the smoke task.

### Review gates

- Gate 5A — Secret gate: Todoist token is private runtime state only; committed files contain only wrapper code and contracts.
- Gate 5B — Idempotency gate: repeated mutation request does not duplicate the external task; the replay returned the same Todoist task id.
- Gate 5C — Live-write gate: the only live write test was an explicit migration smoke task, it was verified through the runtime path, and it was completed afterward.

### Validation notes

- Contract tests passed for idempotency store, mutation runtime helper, task-read wrapper, task runtime/boundary behavior, deadline handling, baseline handling, move-task, retry-partial, write-safety gate, and Todoist API pagination.
- Live health: `jen-task-runtime health` returned `status:"ok"` with token present.
- Live read: `jen-task-read active` returned active tasks from Todoist.
- Live reversible write: two identical `jen-todoist-capture --content "Jen Hermes migration smoke ..."` calls returned the same external Todoist task id, proving replay idempotency for the smoke path; the task was then completed through the Todoist transport.

## Step 6 — Cron/watch/heartbeat

### Execution plan

1. Recreate only essential Jen jobs in Hermes cron: a no-agent health watch and a no-agent new-day readiness read. Do not bulk-import OpenClaw cron jobs.
2. Keep both jobs read-only/no-agent and `deliver: local` until Telegram cutover. Runtime scripts live under ignored `/opt/data/scripts/`; versioned copies live under `agents/public/jen/tools/cron-scripts/`.
3. Run each job manually before relying on recurrence. Gateway is still stopped before Step 7, so jobs are configured and manually validated but will not fire automatically until Jen gateway is live.

### Review gates

- Gate 6A — Job inventory gate: migrated jobs match essential OpenClaw classes (`jen-calendar-auth-watch`/health and `Jen precompute new-day handoff`/new-day readiness); no bulk cron import.
- Gate 6B — Manual-run gate: each cron ran once through `hermes cron run ...` + `hermes cron tick` and produced expected JSON output.
- Gate 6C — Delivery gate: recurrence/delivery is local-only before Telegram, points to Jen runtime cron state, and can be paused/removed by job id.

### Validation notes

- Created Jen runtime cron jobs: `d79831e43d3c` (`Jen health watch`, every 60m, local, no-agent) and `1b8fd906f1f6` (`Jen new-day readiness`, `30 5 * * *`, local, no-agent).
- Manual runs succeeded. Health output reported Todoist `ok` and Calendar `degraded` as expected while Calendar auth is not provisioned. New-day readiness reported Todoist `ok`, due-window count, and `write_actions:[]`.
- Hermes CLI warns the gateway is not running, so recurrence will begin only after Step 7 starts the Jen gateway.

## Step 7 — Telegram cutover

### Execution plan

1. Keep OpenClaw Jen Telegram path live until Hermes Jen passes all local tests.
2. Activate the verified Jen Telegram token in the private Hermes Jen runtime `.env`, with `TELEGRAM_ALLOWED_USERS=8503464394` and `TELEGRAM_HOME_CHANNEL=8503464394`. The token resolves to `@the_ai_crowd_jen_bot` (`sha256[:12]=b74895c5f7f3`) via Telegram `getMe`; the full token is not committed or logged.
3. Disable only `channels.telegram.accounts.jen.enabled=false` in OpenClaw and restart `openclaw-gateway.service`; leave Roy and Denholm enabled.
4. Start the Hermes Jen gateway in the `the-ai-crowd-jen-1` container and validate Telegram polling.
5. Send a controlled outbound smoke message to the allowed Telegram DM. Inbound direct-message confirmation completed from chat `8503464394`; Hermes Jen logged and answered the DM.

### Review gates

- Gate 7A — Cutover gate: OpenClaw Jen disabled; other OpenClaw bots untouched.
- Gate 7B — Hermes gateway gate: Jen Telegram connects in polling mode with no `409 Conflict`; outbound smoke and inbound DM response both succeed.
- Gate 7C — Rollback gate: documented rollback path to stop Hermes Jen gateway and restore the OpenClaw backup.

### Validation notes

- OpenClaw backup before cutover: `/home/rcortese/.openclaw/openclaw.json.before-jen-hermes-telegram-cutover-20260524T160459`.
- Hermes Jen env backup before token activation: `/opt/data/.env.before-telegram-cutover`.
- OpenClaw account state after restart: `jen=false`, `roy=true`, `denholm=true`, `default=false`.
- Hermes Jen gateway status: running manually in `the-ai-crowd-jen-1`; Telegram connected in polling mode.
- Hermes Jen cron warning cleared after gateway start; configured local no-agent jobs remain active.
- Outbound Telegram smoke message sent to chat `8503464394` with message id `568`. Inbound DM from `8503464394` was logged at 16:06 and Hermes Jen sent a response at 16:07.
- No Telegram `409 Conflict` was seen in the checked Hermes/OpenClaw logs after cutover.

### Rollback

1. Stop the Hermes Jen gateway process in `the-ai-crowd-jen-1`.
2. Restore `/home/rcortese/.openclaw/openclaw.json.before-jen-hermes-telegram-cutover-20260524T160459` or set only `channels.telegram.accounts.jen.enabled=true`.
3. Restart `openclaw-gateway.service`.
4. Verify `@the_ai_crowd_jen_bot` is again handled by OpenClaw and that Roy/Denholm remain enabled.

## Final review

Run independent reviews from: new Jen, Moss/Hermes self-review, panel agents, and Moss OpenClaw. Summarize findings and remaining risk.
