#!/usr/bin/env python3
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
dockerfile = (root / "ops/images/Dockerfile.moss-all-in-one").read_text(encoding="utf-8")
helper = (root / "ops/scripts/build-moss-all-in-one-candidate.sh").read_text(encoding="utf-8")
roy_supervisor = (root / "ops/images/roy-all-in-one.supervisor.conf").read_text(encoding="utf-8")
compose = (root / "compose.yaml").read_text(encoding="utf-8")
smoke = (root / "tests/smoke-deploy.sh").read_text(encoding="utf-8")
manifest = root / "ops/build-inputs/moss-clash-royale-war-bot.sha256"

assert manifest.is_file()
entries = manifest.read_text(encoding="utf-8").splitlines()
assert len(entries) == 2
assert entries[0].endswith("  package.json")
assert entries[1].endswith("  package-lock.json")
assert "COPY --from=clash_royale_build_input package.json" in dockerfile
assert "COPY agents/private/moss/projects/clash-royale-war-bot" not in dockerfile
assert "ARG HERMES_WEBUI_VERSION" in dockerfile
assert 'test -n "$HERMES_WEBUI_VERSION"' in dockerfile
assert "printf \"__version__ = '%s'\\\\n\" \"$HERMES_WEBUI_VERSION\"" in dockerfile
for legacy_patch in (
    "moss-agent-health-auth.patch",
    "moss-profile-selector-order.patch",
    "moss-remote-proxy-routing.patch",
    "moss-service-session-launch.patch",
    "moss-terminal-state-false-no-response.patch",
    "moss-title-topic-priority.patch",
):
    assert legacy_patch not in dockerfile
    assert not (root / "ops/hermes-webui-overrides" / legacy_patch).exists()
for target_native_test in (
    "tests/test_agent_health_remote.py",
    "tests/test_issue716_agent_heartbeat.py",
    "tests/test_kanban_bridge.py",
    "tests/test_remote_cron_proxy_guard.py",
    "tests/test_webui_gateway_chat_backend.py",
    "tests/test_stage364_opus_live_sse_event_id.py",
    "tests/test_issue5141_terminal_failure_transcript_evaluator.py",
    "tests/test_session_channel_option_x.py",
):
    assert target_native_test in dockerfile
assert "tests/test_profile_proxy_jen.py" not in dockerfile
assert "tests/test_service_session_launch.py" not in dockerfile
assert 'ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"' in helper
assert 'ROOT="$(git rev-parse --show-toplevel)"' not in helper
assert 'BASE_IMAGE="${MOSS_BASE_IMAGE:-}"' in helper
assert 'MOSS_BASE_IMAGE must be an immutable local sha256 image ID' in helper
assert 'base_alias="the-ai-crowd/moss-build-base:${BASE_IMAGE#sha256:}"' in helper
assert '--build-arg "MOSS_BASE_IMAGE=$base_alias"' in helper
assert "git -C \"$ROOT\" archive --format=tar \"$COMMIT\"" in helper
assert "sha256sum -c \"$CTX/$MANIFEST_REL\"" in helper
assert 'org.opencontainers.image.revision=' in helper
assert 'org.opencontainers.image.source=' in helper
assert 'WEBUI_VERSION="${HERMES_WEBUI_VERSION:?' in helper
assert '--build-arg "HERMES_WEBUI_VERSION=$WEBUI_VERSION"' in helper
for label in (
    "the-ai-crowd.agent-source-commit",
    "the-ai-crowd.agent-source-tree",
    "the-ai-crowd.webui-source-commit",
    "the-ai-crowd.webui-source-tree",
    "the-ai-crowd.webui-version",
):
    assert label in helper
builder = (root / 'ops/scripts/build-persona-base-candidate.sh').read_text(encoding='utf-8')
assert 'HERMES_AGENT_IMAGE_ID' in builder
assert 'HERMES_AGENT_SOURCE_REVISION' in builder
assert 'HERMES_AGENT_SOURCE_TREE' in builder
assert 'Agent source revision label mismatch' in builder
assert 'Agent source tree label mismatch' in builder
assert 'the-ai-crowd.hermes-base-source-tree' in builder
assert 'org.opencontainers.image.revision=' in builder
assert 'org.opencontainers.image.source=' in builder
assert "--build-context \"clash_royale_build_input=$INPUT_DIR\"" in helper
browser_manifest = root / "ops/build-inputs/moss-playwright-browsers.sha256"
assert browser_manifest.is_file()
assert "--build-context \"clash_royale_browser_input=$BROWSER_DIR\"" in helper
assert "COPY --from=clash_royale_browser_input / /opt/playwright-browsers/" in dockerfile
assert "npx playwright install chromium" not in dockerfile
assert "cached_playwright_chromium_smoke_ok" in dockerfile
for legacy_path in (
    'ops/images/Dockerfile.moss-a2a-overlay',
    'ops/images/Dockerfile.runtime-a2a-overlay',
    'ops/scripts/build-moss-a2a-overlay-candidate.sh',
    'ops/scripts/build-runtime-a2a-overlay-candidate.sh',
    'ops/scripts/materialize-persona-toolset-runtime.py',
):
    assert not (root / legacy_path).exists()
assert "HERMES_KANBAN_" not in roy_supervisor
assert "[program:roy-gateway]" in roy_supervisor
for persona in ("denholm", "richmond", "the-elders"):
    dockerfile_text = (root / f"ops/images/Dockerfile.{persona}").read_text(encoding="utf-8")
    assert 'CMD ["gateway", "run"]' in dockerfile_text
assert "command:\n    - gateway\n    - run" not in compose
assert "image: ${MOSS_IMAGE_REF:?" in compose
assert "additional_contexts:" not in compose
assert "MOSS_BASE_IMAGE:" not in compose
assert "ports: !reset []" in smoke
assert "networks: !reset [smoke]" in smoke
assert "env_file: !reset []" in smoke
assert "volumes: !override" in smoke
assert "API_SERVER_KEY: moss-smoke-isolated-api-key" in smoke
assert "smoke_deploy_failed: isolated API key missing" in smoke
assert "TELEGRAM_BOT_TOKEN: ''" in smoke
assert '"${compose[@]}" down --remove-orphans --volumes' in smoke
assert 'export MOSS_IMAGE_REF="$MOSS_SMOKE_IMAGE_ID"' in smoke
assert 'curl -fsS http://127.0.0.1:8787/health' in smoke
assert 'curl -fsS http://127.0.0.1:8648/health' in smoke
assert 'curl -fsS http://127.0.0.1:8644/health' not in smoke
print("moss-candidate-build-contract: PASS")
