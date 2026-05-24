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

1. Port/adapt `jen-task-runtime`, Todoist API transport, mutation gateway, and idempotency store.
2. Wire Todoist credential class privately.
3. Validate read-only task listing, then a reversible authorized test mutation if safe.

### Review gates

- Gate 5A — Secret gate: Todoist token is private runtime state only.
- Gate 5B — Idempotency gate: repeated mutation request does not duplicate external task/event.
- Gate 5C — Live-write gate: any write test is explicit, reversible, and verified in Todoist.

## Step 6 — Cron/watch/heartbeat

### Execution plan

1. Recreate only essential Jen jobs in Hermes cron.
2. Preserve no-proactive-morning and no-spam heartbeat policy.
3. Run each job manually before enabling recurring delivery.

### Review gates

- Gate 6A — Job inventory gate: migrated jobs match essential OpenClaw classes; no bulk cron import.
- Gate 6B — Manual-run gate: each cron can run once and produce expected output or `NO_REPLY`.
- Gate 6C — Delivery gate: recurrence/delivery points to Jen, not Moss, and has disable path.

## Step 7 — Telegram cutover from OpenClaw Jen to Hermes Jen

### Execution plan

1. Stop/disable OpenClaw Jen Telegram handling without disturbing Moss/OpenClaw globally where possible.
2. Configure Hermes Jen Telegram using Jen token/allowlist/private channel state.
3. Start/recreate Jen Hermes gateway and test a direct Telegram conversation.

### Review gates

- Gate 7A — Single-writer gate: only one Jen Telegram consumer is active after cutover.
- Gate 7B — Identity gate: Telegram reply identifies as Jen and handles productivity domain.
- Gate 7C — Rollback gate: OpenClaw Jen fallback or token restore path is documented before cutover.

## Final review

Run independent reviews from: new Jen, Moss/Hermes self-review, panel agents, and Moss OpenClaw. Summarize findings and remaining risk.
