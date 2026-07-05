# WebUI valid context-meter production deploy evidence

Run: `webui-valid-context-meter-deploy-20260703T171520Z`

## Production deploy result
- Status: `success`
- Service: `moss`
- Container: `the-ai-crowd-moss-1`
- Deploy completed at: `2026-07-03T17:33:08Z`
- Stack head used by runner: `8084f5dbd25faff3c693a89fd216a857ffc08aef`
- WebUI revision deployed: `9099d8e72c844cc6cd2acb80e6fbddd2e305aa03`

## Image
- Candidate tag: `the-ai-crowd/moss-all-in-one:webui-valid-context-meter-20260703T170314Z`
- Candidate ID: `sha256:033a117dcb0cfecd7094b22f08839daa41f68de57a8ed0f45e2052316991cae6`
- New production container image ID: `sha256:033a117dcb0cfecd7094b22f08839daa41f68de57a8ed0f45e2052316991cae6`
- Rollback tag: `the-ai-crowd/moss-all-in-one:rollback-before-valid-context-meter-webui-valid-context-meter-deploy-20260703T171520Z`

## Idle gate
Runner waited until WebUI `/health` showed:
- `active_streams: 0`
- `active_runs: 0`

Only after that did it retag the candidate and recreate the `moss` service.

## Post-deploy validation
- Container state: `running`
- Container health: `healthy`
- WebUI `/health`: `status: ok`
- WebUI version: `v0.51.150-2991-g9099d8e7`
- Persona/bot name: `Moss`
- Gateway health: `{"status": "ok", "platform": "hermes-agent", "version": "0.18.0"}`
- Baked code readback confirmed:
  - `_gateway_resolve_context_length`
  - `known_context_length`
  - `prompt_tokens` / `input_tokens` mapped to `last_prompt_tokens`
  - `_gateway_stream_usage(..., context_length=known_context_length)` in gateway paths

## Durable runner artifacts
Ignored operational artifacts remain under:
- `/mnt/user/appdata/the-ai-crowd/ops/candidates/webui-valid-context-meter-deploy-20260703T171520Z/status.json`
- `/mnt/user/appdata/the-ai-crowd/ops/candidates/webui-valid-context-meter-deploy-20260703T171520Z/deploy.log`

Session-specific runner/launch files in `ops/` were removed after this evidence was preserved.
