# WebUI API context-meter source/build evidence

Run: webui-context-meter-20260703T163537Z

## Purpose
Fix the WebUI/API context meter false-low/fake percentage issue in a way that survives rebuild.

## WebUI source commit
- Repo: `git@github.com:rcortese/hermes-webui.git`
- Branch: `the-ai-crowd/webui-v0.51.820-profile-proxy-20260702T042732Z`
- Commit: `1e8c6d230f7602a1bd06fced2a6cdbee2a41b073`
- Message: `fix(webui): avoid fake context percentages in API bridge`

## Stack source commit that pinned the WebUI revision
- Repo: `git@github.com:rcortese/the-ai-crowd-hermes.git`
- Branch at initial pin: `fix/codex-shared-auth-store`
- Commit: `4a1909d036a1015fca64fd57de550f0c0688fb6c`
- File: `ops/images/Dockerfile.moss-all-in-one`
- Pin: `ARG HERMES_WEBUI_REV=1e8c6d230f7602a1bd06fced2a6cdbee2a41b073`

## Candidate image
- Tag: `the-ai-crowd/moss-all-in-one:webui-context-meter-20260703T163537Z`
- Image ID: `sha256:da329ad244366441098ba726fd847d0cdd6d8142542158c3bb868bf98f109499`

## Validation run
Focused WebUI checkout tests in disposable container:

`docker run --rm -v <webui-checkout>:/work -v <test-state>:/tmp/hermes-webui-tests -w /work --entrypoint /bin/bash the-ai-crowd/moss-all-in-one:local -lc 'export HERMES_WEBUI_TEST_STATE_ROOT=/tmp/hermes-webui-tests; /opt/hermes/.venv/bin/python3 -m pytest -q tests/test_webui_gateway_chat_backend.py tests/test_mobile_layout.py tests/test_streaming_live_usage_estimate.py tests/test_pr1318_context_length_fallback.py'`

Result: `120 passed in 3.07s`.

Candidate image build validation:

- Dockerfile build completed successfully.
- Dockerfile WebUI test gate result: `131 passed in 5.29s`.
- Candidate baked WebUI version: `__version__ = 'v0.51.150-2990-g1e8c6d23'`.
- Candidate readback confirmed the baked image contains:
  - `api/gateway_chat.py` preserving `last_prompt_tokens`, `context_length`, and related context metadata.
  - `static/ui.js` using `hasMeasuredCtx` and `context window unknown` instead of a fake 128K fallback percentage.

## Production status
No production Moss/WebUI cutover was performed in this run. The running Moss service was not stopped, restarted, recreated, or removed.

Production cutover requires separate explicit approval because it recreates/restarts the Moss WebUI surface.
