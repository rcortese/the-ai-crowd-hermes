#!/usr/bin/env python3
"""Causal source-archive contract for Roy's WebUI api_server backend."""
from __future__ import annotations

import io
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile

root = Path(sys.argv[1]).resolve()
validator = root / "ops/scripts/verify-hermes-webui-api-server-contract.py"
dockerfile = (root / "ops/images/Dockerfile.roy-all-in-one").read_text(encoding="utf-8")
supervisor = (root / "ops/images/roy-all-in-one.supervisor.conf").read_text(encoding="utf-8")
assert "COPY ops/scripts/verify-hermes-webui-api-server-contract.py" in dockerfile
assert "python3 /tmp/verify-hermes-webui-api-server-contract.py /tmp/hermes-webui.tar" in dockerfile
assert "test -f /opt/hermes-webui/api/gateway_chat.py" in dockerfile
assert "/opt/hermes-webui/server.py /opt/hermes-webui/api/gateway_chat.py" in dockerfile

# The archive capability and deployed supervisor must agree on the api_server
# selector, Roy's internal endpoint, and API_SERVER_KEY resolution path.
for literal in (
    'HERMES_WEBUI_CHAT_BACKEND="api_server"',
    'HERMES_WEBUI_GATEWAY_BASE_URL="http://roy:8645"',
    'HERMES_WEBUI_GATEWAY_API_KEY="%(ENV_API_SERVER_KEY)s"',
):
    assert literal in supervisor


def archive(path: Path, members: dict[str, str]) -> None:
    with tarfile.open(path, "w") as bundle:
        for name, text in members.items():
            payload = text.encode("utf-8")
            entry = tarfile.TarInfo(name)
            entry.size = len(payload)
            bundle.addfile(entry, io.BytesIO(payload))


def run(bundle: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(validator), str(bundle)],
        text=True,
        capture_output=True,
        check=False,
    )


gateway_source = '''\
import os
_WEBUI_CHAT_BACKEND_ENV = "HERMES_WEBUI_CHAT_BACKEND"
_GATEWAY_CHAT_BACKENDS = {"gateway", "api_server", "api-server"}
_WEBUI_GATEWAY_BASE_URL_ENV = "HERMES_WEBUI_GATEWAY_BASE_URL"
_WEBUI_GATEWAY_API_KEY_ENV = "HERMES_WEBUI_GATEWAY_API_KEY"
def _gateway_base_url():
    return os.environ.get(_WEBUI_GATEWAY_BASE_URL_ENV, "http://127.0.0.1:8642")
def _gateway_api_key():
    return os.environ.get(_WEBUI_GATEWAY_API_KEY_ENV) or os.environ.get("API_SERVER_KEY") or ""
'''


def assert_rejected(name: str, source: str, diagnostic: str, tmp: Path) -> None:
    bundle = tmp / f"{name}.tar"
    archive(bundle, {"server.py": "import api.gateway_chat\n", "api/gateway_chat.py": source})
    result = run(bundle)
    assert result.returncode != 0, result.stdout
    assert diagnostic in result.stderr, result.stderr


with tempfile.TemporaryDirectory(prefix="roy-webui-archive-contract.") as tmpdir:
    tmp = Path(tmpdir)
    valid = tmp / "valid.tar"
    archive(valid, {"server.py": "import api.gateway_chat\n", "api/gateway_chat.py": gateway_source})
    result = run(valid)
    assert result.returncode == 0, result.stderr
    assert "PASS" in result.stdout

    assert_rejected(
        "missing-api-server-selector",
        gateway_source.replace('"api_server", ', ""),
        "api_server backend selector",
        tmp,
    )
    assert_rejected(
        "changed-gateway-base-url",
        gateway_source.replace("HERMES_WEBUI_GATEWAY_BASE_URL", "HERMES_WEBUI_GATEWAY_URL"),
        "gateway base URL resolution",
        tmp,
    )
    assert_rejected(
        "missing-api-server-key-fallback",
        gateway_source.replace(' or os.environ.get("API_SERVER_KEY")', ""),
        "API_SERVER_KEY fallback",
        tmp,
    )

    missing = tmp / "missing-gateway.tar"
    archive(missing, {"server.py": "pass\n"})
    result = run(missing)
    assert result.returncode != 0
    assert "api/gateway_chat.py" in result.stderr

    broken = tmp / "broken-gateway.tar"
    archive(broken, {"server.py": "pass\n", "api/gateway_chat.py": "def broken(:\n"})
    result = run(broken)
    assert result.returncode != 0
    assert "compile" in result.stderr

print("roy-webui-api-server-archive-contract: PASS positive=1 negative=5")
