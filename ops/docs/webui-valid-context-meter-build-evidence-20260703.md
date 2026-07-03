# WebUI API valid context-meter source/build evidence

Run: webui-valid-context-meter-20260703T170314Z

## Purpose
Fix the WebUI/API context meter so the normal Gateway-backed path reports a known, valid context percentage rather than a fabricated 1% or an unknown context window.

## WebUI source commit
- Repo: `git@github.com:rcortese/hermes-webui.git`
- Branch: `the-ai-crowd/webui-v0.51.820-profile-proxy-20260702T042732Z`
- Commit: `9099d8e72c844cc6cd2acb80e6fbddd2e305aa03`
- Message: `fix(webui): resolve valid context meter for gateway chat`

## Behavior
- `api/gateway_chat.py::_gateway_stream_usage` maps OpenAI-compatible `prompt_tokens`/`input_tokens` to `last_prompt_tokens` for the current request when Hermes-native `last_prompt_tokens` is absent.
- `api/gateway_chat.py::_gateway_resolve_context_length` delegates to shared `api.routes._resolve_context_length_for_session_model` using model/provider/base_url/api_key.
- Chat Completions and Runs API gateway paths compute `known_context_length` once and pass it into `_gateway_stream_usage`.
- Explicit Hermes-native `last_prompt_tokens` and `context_length` from the gateway payload still win.
- `static/ui.js` still refuses to fabricate a fallback window, but the normal gateway path now provides measured `last_prompt_tokens` plus resolved `context_length`.

## Stack source pin
- Repo: `git@github.com:rcortese/the-ai-crowd-hermes.git`
- Branch: `fix/codex-shared-auth-store`
- Pin correction/head at evidence time: `bd79e6d9f5194789e405fb14a18f906f9f5b7c87`
- File: `ops/images/Dockerfile.moss-all-in-one`
- Pin: `ARG HERMES_WEBUI_REV=9099d8e72c844cc6cd2acb80e6fbddd2e305aa03`

Note: commit `e90067afca1a8040ed9d7731189785285308bd4f` accidentally included unrelated local Dockerfile overlay edits while changing the pin. Commit `bd79e6d9f5194789e405fb14a18f906f9f5b7c87` corrected the Dockerfile so the current source state keeps only the WebUI pin change relative to the prior valid source.

## Validation
Focused WebUI tests in disposable container mounting the persistent WebUI checkout:

`tests/test_webui_gateway_chat_backend.py tests/test_mobile_layout.py tests/test_streaming_live_usage_estimate.py tests/test_pr1318_context_length_fallback.py tests/test_issue3717_context_length_provider_overrides.py`

Result: `127 passed in 3.35s`.

Candidate image build:
- Tag: `the-ai-crowd/moss-all-in-one:webui-valid-context-meter-20260703T170314Z`
- Image ID: `sha256:033a117dcb0cfecd7094b22f08839daa41f68de57a8ed0f45e2052316991cae6`
- Dockerfile WebUI test gate: `132 passed in 5.44s`
- Baked WebUI version: `__version__ = 'v0.51.150-2991-g9099d8e7'`

Baked image readback confirmed:
- `def _gateway_resolve_context_length` exists in `/opt/hermes-webui/api/gateway_chat.py`.
- `known_context_length` is passed to `_gateway_stream_usage` in gateway paths.
- `prompt_tokens`/`input_tokens` are mapped to `last_prompt_tokens` when explicit metadata is absent.
- UI retains `hasMeasuredCtx`, so it displays a percent only when both measured prompt tokens and resolved context length are present.

## Production status
No production Moss/WebUI cutover was performed. The running Moss service was not stopped, restarted, recreated, or removed.

Production cutover requires separate explicit approval because it recreates/restarts the Moss WebUI surface.
