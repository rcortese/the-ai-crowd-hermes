# Roy isolation posture

This repository carries only public-safe source/config posture for Roy. Live cutover, secrets, private DNS, reverse-proxy credentials, OAuth callbacks, and runtime homes remain deployment/runtime state.

## Source/config posture

- Roy stays Roy externally; do not fork the user-facing identity merely because a trusted user is configured.
- Hermes/Moss may expose a one-way operator proxy to Roy through `HERMES_WEBUI_PROFILE_PROXY_ROY_*` so the configured operator can reach Roy from the private operator endpoint.
- That proxy is asymmetric. It does not make Roy part of the Moss operator cockpit and does not grant Roy reciprocal visibility into Moss or other personas.
- Roy's own private WebUI route may exist, but it must remain Roy-scoped: no profile switcher, gateway switcher, shared Kanban, fleet dashboards, other agents, other sessions, raw auth, or runtime DBs.
- Roy uses a dedicated operational Kanban root: `/mnt/hermes-shared/kanban/roy`. Moss implementation boards may still live in the shared fleet Kanban root, but Roy runtime tasks must not.
- Roy channel wiring stays persona-prefixed in private deployment env files (`ROY_TELEGRAM_*`) and is mapped into generic Hermes env names only inside the Roy container.
- Dashboard port `9123` is not exposed for Roy. The public/private HTTPS route should use the Roy WebUI/API surface that is explicitly configured for Roy.

## Private deployment follow-ups

1. Materialize `runtime/roy-home` privately; do not copy refresh tokens or raw auth state from another Hermes home. Re-auth OpenAI/OAuth inside Roy's own home if needed.
2. Keep Roy's Telegram identity Roy-specific and set private `ROY_TELEGRAM_BOT_TOKEN`, `ROY_TELEGRAM_ALLOWED_USERS`, and `ROY_TELEGRAM_HOME_CHANNEL` values in ignored env files only.
3. If Roy's WebUI endpoint is enabled, wire it in the private reverse proxy using the same internal/private pattern as the operator endpoint. Do not add public scaffold DNS/routes here.
4. Configure Roy's private Honcho/runtime state so the AI peer is Roy and the user peer is the configured trusted user. Keep runtime peer/session state in the private runtime home, not in this source repo.
5. Google MVP should start with Drive `drive.file`, Sheets, and Forms. Do not claim Google persistence works until Roy's private runtime auth succeeds and is read back from the real backend.

## Suggested validations

- `docker compose config` in the private deployment checkout with real ignored env files present.
- `bash tests/health-check.sh` for source-level contracts.
- Container health for Roy WebUI/webhook/API after an approved lifecycle cutover: `8787/health`, `8644/health`, and `8645/health`.
- Confirm Moss may advertise `HERMES_WEBUI_PROFILE_PROXY_ROY_*` as a one-way operator proxy.
- Confirm Roy does not advertise any `HERMES_WEBUI_PROFILE_PROXY_*` entries.
- Confirm Roy's runtime `HERMES_KANBAN_HOME` resolves to the dedicated path.
