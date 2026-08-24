#!/usr/bin/env python3
"""Source-only contract for the Roy all-in-one candidate builder."""
from pathlib import Path
import re
import subprocess
import sys

root = Path(sys.argv[1]).resolve()
dockerfile = (root / "ops/images/Dockerfile.roy-all-in-one").read_text(encoding="utf-8")
builder = (root / "ops/scripts/build-roy-all-in-one-candidate.sh").read_text(encoding="utf-8")
supervisor = (root / "ops/images/roy-all-in-one.supervisor.conf").read_text(encoding="utf-8")
compose = (root / "compose.yaml").read_text(encoding="utf-8")

# The final image consumes only the immutable Roy base candidate and an exact,
# checksum-verified WebUI archive. No default branch/tag is permitted.
assert "ARG ROY_BASE_IMAGE" in dockerfile
assert "FROM ${ROY_BASE_IMAGE}" in dockerfile
for arg in ("HERMES_WEBUI_REPO", "HERMES_WEBUI_REV", "HERMES_WEBUI_ARCHIVE_SHA256"):
    assert f"ARG {arg}" in dockerfile
assert "grep -Eq '^[0-9a-f]{40}$'" in dockerfile
assert "grep -Eq '^[0-9a-f]{64}$'" in dockerfile
assert 'git checkout --detach "${HERMES_WEBUI_REV}"' in dockerfile
assert 'test "$(git rev-parse HEAD)" = "${HERMES_WEBUI_REV}"' in dockerfile
assert 'git archive --format=tar "${HERMES_WEBUI_REV}"' in dockerfile
assert "sha256sum -c -" in dockerfile
assert "test -f /opt/hermes-webui/server.py" in dockerfile
assert "test -f /opt/hermes-webui/api/gateway_chat.py" in dockerfile
assert "python3 /tmp/verify-hermes-webui-api-server-contract.py /tmp/hermes-webui.tar" in dockerfile
assert "/opt/hermes-webui/server.py /opt/hermes-webui/api/gateway_chat.py" in dockerfile
assert "test ! -e /opt/hermes-webui/.git" in dockerfile
assert "test ! -e /opt/hermes-webui/venv" in dockerfile
assert "COPY ops/images/roy-all-in-one.supervisor.conf /etc/supervisor/conf.d/roy-all-in-one.conf" in dockerfile
assert "ENTRYPOINT [\"/usr/bin/supervisord\"" in dockerfile
assert "git clone --depth" not in dockerfile
assert "ARG HERMES_WEBUI_REV=" not in dockerfile

# The deployed Roy Compose contract needs all-in-one WebUI and both gateway
# surfaces; the healthcheck cannot silently substitute the dashboard port.
for literal in ("HERMES_WEBUI_PORT: '8787'", "API_SERVER_PORT: '8645'", "curl -fsS http://127.0.0.1:8787/health", "curl -fsS http://127.0.0.1:8645/health"):
    assert literal in compose
for program in ("roy-gateway", "roy-dashboard", "roy-webui"):
    assert f"[program:{program}]" in supervisor
assert "/opt/hermes-webui/server.py" in supervisor
assert "--port 9123" in supervisor
assert re.search(r"^user=hermes$", supervisor, re.MULTILINE)
# Keep the deployed WebUI process aligned with the archive verifier's exact
# api_server transport: Roy's service endpoint and inherited API_SERVER_KEY.
for literal in (
    'HERMES_WEBUI_CHAT_BACKEND="api_server"',
    'HERMES_WEBUI_GATEWAY_BASE_URL="http://roy:8645"',
    'HERMES_WEBUI_GATEWAY_API_KEY="%(ENV_API_SERVER_KEY)s"',
):
    assert literal in supervisor

# The builder exports the exact candidate tree, verifies the supplied immutable
# base ID, labels all three provenance roots, and publishes a write-once receipt.
assert 'ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"' in builder
assert 'git -C "$ROOT" archive --format=tar "$COMMIT"' in builder
assert 'ROY_BASE_IMAGE must be an immutable local sha256 image ID' in builder
assert 'ROY_WEBUI_REV must be a full immutable Git revision' in builder
assert 'ROY_WEBUI_ARCHIVE_SHA256 must be a Git archive SHA-256' in builder
assert 'ROY_BASE_CANDIDATE_REF must name the required local Roy base candidate' in builder
assert 'docker image inspect "$ROY_BASE_CANDIDATE_REF" --format \'{{.Id}}\'' in builder
assert "Roy base candidate ref does not resolve to ROY_BASE_IMAGE" in builder
for label in (
    "the-ai-crowd.source-commit",
    "the-ai-crowd.source-tree",
    "the-ai-crowd.hermes-base-id",
    "the-ai-crowd.hermes-base-source-revision",
):
    assert f'{{{{index .Config.Labels "{label}"}}}}' in builder
assert "a2bddaf9921c8b8b10f96e188bb61f0a33d9bfc5" in builder
assert "9f483dffbf04b33efb4e7bffd3a0a7247f82e223" in builder
assert "Roy base candidate source labels do not match all-persona stack candidate" in builder
assert "Roy base candidate Hermes base provenance does not match protected base" in builder
assert 'base_alias="the-ai-crowd/roy-build-base:${ROY_BASE_IMAGE#sha256:}"' in builder
assert '--build-arg "ROY_BASE_IMAGE=$base_alias"' in builder
for key in (
    "the-ai-crowd.source-commit",
    "the-ai-crowd.source-tree",
    "the-ai-crowd.roy-base-id",
    "the-ai-crowd.roy-base-candidate-ref",
    "the-ai-crowd.roy-base-source-commit",
    "the-ai-crowd.roy-base-source-tree",
    "the-ai-crowd.roy-base-hermes-base-id",
    "the-ai-crowd.roy-base-hermes-base-source-revision",
    "the-ai-crowd.webui-repository",
    "the-ai-crowd.webui-revision",
    "the-ai-crowd.webui-archive-sha256",
    "org.opencontainers.image.revision",
    "org.opencontainers.image.source",
):
    assert key in builder
for key in (
    "status:$status",
    "source_commit:$source_commit",
    "source_tree:$source_tree",
    "image_id:$image_id",
    "roy_base_image_id:$roy_base_image_id",
    "roy_base_candidate_ref:$roy_base_candidate_ref",
    "roy_base_source_commit:$roy_base_source_commit",
    "roy_base_source_tree:$roy_base_source_tree",
    "roy_base_hermes_base_id:$roy_base_hermes_base_id",
    "roy_base_hermes_base_source_revision:$roy_base_hermes_base_source_revision",
    "webui_repository:$webui_repository",
    "webui_revision:$webui_revision",
    "webui_archive_sha256:$webui_archive_sha256",
    "builder_sha256:$builder_sha256",
):
    assert key in builder
assert "ln \"$tmp\" \"$receipt\"" in builder
assert "divergent or unsafe build receipt already exists" in builder
assert "docker build --pull=false" in builder
subprocess.run(
    ["bash", str(root / "ops/tests/test_roy_all_in_one_candidate_build_contract.sh"), str(root)],
    check=True,
)

print("roy-all-in-one-candidate-contract: PASS")
