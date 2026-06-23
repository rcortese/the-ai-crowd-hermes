# Moss WebUI / Moss runtime split proposal

Date: 2026-06-02
Scope: The AI Crowd `<host>:<stack-root>`
Status: proposal only; no runtime mutation in this artifact.

## Context

The current Moss service is an all-in-one container: one Compose service starts the Moss Gateway/API/Webhook surfaces, dashboard, and Hermes WebUI. That is convenient, but it means direct WebUI execution shares the WebUI container's process environment. The new remote-profile proxy pattern already proves a cleaner boundary for other personas:

```text
WebUI selected profile -> internal Gateway/API Server -> real persona container
```

The same pattern can be applied to Moss itself by separating `moss-webui` from `moss`.

## Recommended target shape

Split the current `moss` service into two responsibilities:

1. `moss` / `moss-agent`
   - Owns Moss identity, HERMES_HOME, gateway/webhook/API server, cron, memory, sessions, private workspace, and technical-ops authority.
   - Exposes an internal API Server endpoint, for example `http://moss:8642` or `http://moss-agent:8642`.
   - Publishes only the externally needed gateway/webhook ports.

2. `moss-webui`
   - Owns only browser UI state, WebUI static/backend code, and profile selector/proxy routing.
   - Has no direct authority to impersonate other personas or mutate their runtime state.
   - Treats `moss`, `jen`, `denholm`, `roy`, etc. as remote profile proxies over internal HTTP/SSE.
   - Stores local WebUI transcript mirrors and correlation metadata, not remote runtime DBs or secrets.

Illustrative routing:

```text
Browser -> moss-webui:8787
  profile=moss     -> http://moss-agent:<api-port>/v1/chat/completions
  profile=jen      -> http://jen:8642/v1/chat/completions
  profile=denholm  -> http://denholm:8643/v1/chat/completions
  profile=roy      -> http://roy:8645/v1/chat/completions
```

## Benefits

- Cleaner identity boundary: WebUI is no longer “Moss because it has Moss's local environment”; it becomes a UI/control plane that routes to the real agent gateway.
- Safer self-replacement: WebUI can be restarted without killing the Moss agent/gateway, and Moss can be restarted without necessarily dropping the browser UI.
- More uniform implementation: all personas, including Moss, use the same remote Gateway/API contract.
- Fewer local-profile ambiguities: selecting `moss` in the WebUI means remote Moss agent, not a local WebUI execution mode unless explicitly configured.
- Reduced blast radius for WebUI bugs: a WebUI dependency or route bug does not directly mutate Moss runtime DBs unless the agent API accepts the request.
- Easier future A2A/AG-UI alignment: WebUI becomes an event bridge rather than an identity container.

## Risks and tradeoffs

- More containers and health checks: one extra service and one more internal API endpoint.
- More auth indirection: WebUI needs internal API keys for Moss and other personas; those must remain env-file based and never appear in public profile responses.
- Session correlation becomes more explicit: browser sessions and remote agent sessions must be correlated by stable session keys.
- Cancellation remains best-effort until Gateway emits canonical run IDs for all streams.
- Migration can temporarily create two Moss surfaces if ports/gateways are not planned carefully.
- If WebUI becomes a generic router, access control and profile visibility need explicit policy; profile selector is not an ACL.

## Migration phases

### Phase 0 — keep current all-in-one, finish live persona proxies

Finish the current Denholm/Roy/Jen proxy rollout first. Do not combine the topology split with the all-persona selector deploy.

### Phase 1 — enable Moss API Server in the current Moss service

Add an internal Moss API Server endpoint while keeping WebUI local execution available as fallback. Validate:

- `GET /health` on Moss API Server from the WebUI network namespace;
- authenticated `/v1/models`;
- deterministic streaming smoke through `/v1/chat/completions`;
- no API key leak in WebUI public payloads.

### Phase 2 — add `moss` as an explicit remote profile proxy inside current WebUI

Before splitting containers, make the current WebUI route `profile=moss` to the Moss API Server, while preserving local `default` only as an emergency/debug profile. Validate fail-closed behavior: if Moss API Server is unavailable, WebUI must not silently answer as local Moss.

### Phase 3 — introduce `moss-webui` service

Create a new WebUI-only image/service with its own `/opt/data/webui` state and internal proxy env. Keep it on the same internal network. Do not mount Moss runtime DBs/secrets into `moss-webui`; mount only what WebUI genuinely needs.

### Phase 4 — move the external/browser entrypoint to `moss-webui`

Switch browser-facing port/route to `moss-webui` after smoke tests pass. Keep the old all-in-one WebUI disabled or internal-only during a short rollback window.

### Phase 5 — remove all-in-one coupling

Once stable, remove supervisor responsibility for WebUI from the Moss agent container. Moss owns agent/gateway; WebUI owns browser/UI.

## Rollback plan

- Keep the current all-in-one image/tag until split validation completes.
- Roll back browser routing to the current `moss` WebUI port if `moss-webui` fails.
- Keep remote persona proxy env scoped and reversible in Compose.
- Do not delete Moss local WebUI state until transcript/session implications are reviewed.

## Acceptance criteria for a future implementation card

- `moss-webui` and `moss-agent` are separate services.
- Selecting `moss` routes to the real Moss agent API Server.
- Selecting `jen`, `denholm`, and `roy` continues to route to their own containers.
- No persona secrets, auth stores, session DBs, memory DBs, cron, or plugin state are copied into WebUI.
- WebUI public `/api/profiles` exposes labels/kinds/health without raw API keys.
- Offline remote agent produces a clear proxy error and no local impersonation.
- Restart tests prove WebUI can restart without replacing the Moss agent container.

## Recommendation

Do not do this split in the same cutover as the Denholm/Roy expansion. Finish the all-persona remote selector first with one restart. Then create a separate Kanban board/graph for the Moss/WebUI split, because it changes service topology and failure domains rather than just adding proxy mappings.
