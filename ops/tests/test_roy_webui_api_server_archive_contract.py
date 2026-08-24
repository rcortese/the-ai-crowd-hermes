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
def webui_chat_backend_mode():
    raw = os.environ.get(_WEBUI_CHAT_BACKEND_ENV) or ""
    if raw == "api_server":
        return "api_server"
    return "legacy"
def webui_gateway_chat_enabled():
    return webui_chat_backend_mode() == "api_server"
def _gateway_base_url():
    return os.environ.get(_WEBUI_GATEWAY_BASE_URL_ENV, "http://127.0.0.1:8642")
def _gateway_api_key():
    return os.environ.get(_WEBUI_GATEWAY_API_KEY_ENV) or os.environ.get("API_SERVER_KEY") or ""
def _gateway_transport(base_url, api_key):
    return (base_url, api_key)
def _run_gateway_chat_streaming():
    if webui_chat_backend_mode() == "api_server":
        return _gateway_transport(_gateway_base_url(), _gateway_api_key())
    return None
'''

routes_source = '''\
from api.gateway_chat import _run_gateway_chat_streaming, webui_gateway_chat_enabled

def handle_post():
    path = "/api/chat/start"
    if path == "/api/chat/start" and webui_gateway_chat_enabled():
        return _run_gateway_chat_streaming()
    if path == "/api/chat/start":
        return _run_legacy_chat_streaming()
    return None

def _handle_chat_start():
    return _start_chat_stream()

def _start_chat_stream():
    return _run_legacy_chat_streaming()

def _run_legacy_chat_streaming():
    return None
'''

server_source = '''\
from api import gateway_chat, routes

def do_POST():
    return routes.handle_post()

def warm_gateway():
    return gateway_chat.webui_gateway_chat_enabled()
'''


def assert_rejected(name: str, members: dict[str, str], diagnostic: str, tmp: Path) -> None:
    bundle = tmp / f"{name}.tar"
    archive(bundle, members)
    result = run(bundle)
    assert result.returncode != 0, result.stdout
    assert diagnostic in result.stderr, result.stderr


def members(*, server: str = server_source, routes: str = routes_source, gateway: str = gateway_source) -> dict[str, str]:
    return {"server.py": server, "api/routes.py": routes, "api/gateway_chat.py": gateway}


with tempfile.TemporaryDirectory(prefix="roy-webui-archive-contract.") as tmpdir:
    tmp = Path(tmpdir)
    valid = tmp / "valid.tar"
    archive(valid, members())
    result = run(valid)
    assert result.returncode == 0, result.stderr
    assert "PASS" in result.stdout

    assert_rejected(
        "missing-api-server-selector",
        members(gateway=gateway_source.replace('"api_server", ', "")),
        "api_server backend selector",
        tmp,
    )
    assert_rejected(
        "changed-gateway-base-url",
        members(gateway=gateway_source.replace("HERMES_WEBUI_GATEWAY_BASE_URL", "HERMES_WEBUI_GATEWAY_URL")),
        "gateway base URL resolution",
        tmp,
    )
    assert_rejected(
        "missing-api-server-key-fallback",
        members(gateway=gateway_source.replace(' or os.environ.get("API_SERVER_KEY")', "")),
        "API_SERVER_KEY fallback",
        tmp,
    )
    # Keep selector/constants/helper declarations byte-for-byte intact, but
    # sever the active api_server branch from the configured transport.
    assert_rejected(
        "api-server-disconnected-from-transport",
        members(gateway=gateway_source.replace(
            "return _gateway_transport(_gateway_base_url(), _gateway_api_key())",
            "return None",
        )),
        "api_server branch does not directly call gateway transport",
        tmp,
    )
    # A benign gateway activation must not substitute for the actual public
    # chat dispatch. This retains all gateway declarations and route wiring,
    # but sends do_POST to a direct legacy handler instead of api.routes.
    direct_legacy_server = server_source.replace(
        "return routes.handle_post()",
        "return _legacy_direct_chat()",
    ) + '''\
def _legacy_direct_chat():
    return None
'''
    assert_rejected(
        "public-dispatch-direct-legacy",
        members(server=direct_legacy_server),
        "server do_POST does not reach api.routes.handle_post",
        tmp,
    )
    # A public helper may reach routes while the actual HTTP do_POST handler
    # remains legacy; only do_POST is an acceptable server entrypoint.
    do_post_legacy_with_unrelated_routes_helper = '''\
from api import gateway_chat, routes

def do_POST():
    return _legacy_direct_chat()

def _legacy_direct_chat():
    return None

def unrelated_routes_helper():
    return routes.handle_post()

def warm_gateway():
    return gateway_chat.webui_gateway_chat_enabled()
'''
    assert_rejected(
        "do-post-legacy-unrelated-routes-helper",
        members(server=do_post_legacy_with_unrelated_routes_helper),
        "server do_POST does not reach api.routes.handle_post",
        tmp,
    )
    # The /api/chat/start branch itself must select/launch the gateway path;
    # an unrelated helper is not evidence that this route dispatches there.
    chat_start_legacy_with_unrelated_gateway_helper = '''\
from api.gateway_chat import _run_gateway_chat_streaming, webui_gateway_chat_enabled

def handle_post():
    path = "/api/chat/start"
    if path == "/api/chat/start":
        return _run_legacy_chat_streaming()
    return None

def unrelated_gateway_helper():
    if webui_gateway_chat_enabled():
        return _run_gateway_chat_streaming()
    return None

def _run_legacy_chat_streaming():
    return None
'''
    assert_rejected(
        "chat-start-legacy-unrelated-gateway-helper",
        members(routes=chat_start_legacy_with_unrelated_gateway_helper),
        "api.routes /api/chat/start branch does not directly call gateway selector/runner",
        tmp,
    )
    # A transport hidden in another branch must not satisfy the api_server
    # branch: that branch itself must consume both configured gateway helpers.
    api_server_legacy_with_else_transport = gateway_source.replace(
        "return _gateway_transport(_gateway_base_url(), _gateway_api_key())\n    return None",
        "return None\n    return _gateway_transport(_gateway_base_url(), _gateway_api_key())",
    )
    assert_rejected(
        "api-server-legacy-else-transport",
        members(gateway=api_server_legacy_with_else_transport),
        "api_server branch does not directly call gateway transport consuming configured URL/key helpers",
        tmp,
    )

    missing = tmp / "missing-gateway.tar"
    archive(missing, {"server.py": "pass\n", "api/routes.py": "pass\n"})
    result = run(missing)
    assert result.returncode != 0
    assert "api/gateway_chat.py" in result.stderr

    broken = tmp / "broken-gateway.tar"
    archive(broken, {"server.py": "pass\n", "api/routes.py": "pass\n", "api/gateway_chat.py": "def broken(:\n"})
    result = run(broken)
    assert result.returncode != 0
    assert "compile" in result.stderr

print("roy-webui-api-server-archive-contract: PASS positive=1 negative=10")
