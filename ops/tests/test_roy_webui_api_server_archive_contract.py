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

for literal in (
    "COPY ops/scripts/verify-hermes-webui-api-server-contract.py",
    "python3 /tmp/verify-hermes-webui-api-server-contract.py /tmp/hermes-webui.tar",
    "test -f /opt/hermes-webui/api/gateway_chat.py",
    "/opt/hermes-webui/server.py /opt/hermes-webui/api/gateway_chat.py",
    'HERMES_WEBUI_CHAT_BACKEND="api_server"',
    'HERMES_WEBUI_GATEWAY_BASE_URL="http://roy:8645"',
    'HERMES_WEBUI_GATEWAY_API_KEY="%(ENV_API_SERVER_KEY)s"',
):
    assert literal in (dockerfile + supervisor)


def archive(path: Path, members: dict[str, str]) -> None:
    with tarfile.open(path, "w") as bundle:
        for name, text in members.items():
            payload = text.encode("utf-8")
            entry = tarfile.TarInfo(name)
            entry.size = len(payload)
            bundle.addfile(entry, io.BytesIO(payload))


def run(bundle: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run([sys.executable, str(validator), str(bundle)], text=True, capture_output=True, check=False)


gateway_source = '''\
import os
_WEBUI_CHAT_BACKEND_ENV = "HERMES_WEBUI_CHAT_BACKEND"
_GATEWAY_CHAT_BACKENDS = {"gateway", "api_server", "api-server"}
_WEBUI_GATEWAY_BASE_URL_ENV = "HERMES_WEBUI_GATEWAY_BASE_URL"
_WEBUI_GATEWAY_API_KEY_ENV = "HERMES_WEBUI_GATEWAY_API_KEY"
def webui_chat_backend_mode(config_data=None, environ=None):
    source = os.environ if environ is None else environ
    cfg = config_data if isinstance(config_data, dict) else {}
    raw = str(source.get(_WEBUI_CHAT_BACKEND_ENV) or cfg.get("webui_chat_backend") or "").strip().lower()
    if raw in _GATEWAY_CHAT_BACKENDS:
        return "gateway"
    return "legacy"
def webui_gateway_chat_enabled(config_data=None, environ=None):
    return webui_chat_backend_mode(config_data, environ) == "gateway"
def _gateway_base_url(config_data=None, environ=None):
    source = os.environ if environ is None else environ
    cfg = config_data if isinstance(config_data, dict) else {}
    raw = str(source.get(_WEBUI_GATEWAY_BASE_URL_ENV) or cfg.get("webui_gateway_base_url") or "http://127.0.0.1:8642").strip()
    return raw.rstrip("/") or "http://127.0.0.1:8642"
def _gateway_api_key(environ=None):
    source = os.environ if environ is None else environ
    return str(source.get(_WEBUI_GATEWAY_API_KEY_ENV) or source.get("API_SERVER_KEY") or "").strip()
def _run_gateway_chat_streaming(session_id, msg, model, workspace, stream_id, attachments=None, *, model_provider=None, gateway_config=None):
    cfg = get_config()
    base_url = _gateway_base_url(cfg)
    api_key = _gateway_api_key()
    return _gateway_transport(base_url, api_key)
'''

routes_source = '''\
from api.gateway_chat import _run_gateway_chat_streaming, webui_gateway_chat_enabled
def handle_post(handler, parsed):
    if parsed.path == "/api/chat/start":
        return _handle_chat_start(handler)
    return False
def _handle_chat_start(handler):
    cfg = get_config()
    backend_is_gateway = webui_gateway_chat_enabled(cfg)
    worker_target = _run_gateway_chat_streaming if backend_is_gateway else _run_agent_streaming
    return threading.Thread(target=worker_target)
'''

server_source = '''\
from urllib.parse import urlparse
from api.routes import handle_post
class Handler:
    def do_POST(self):
        return self._handle_write(handle_post)
    def _handle_write(self, route_func):
        parsed = urlparse(self.path)
        return route_func(self, parsed)
'''


def members(*, server=server_source, routes=routes_source, gateway=gateway_source):
    return {"server.py": server, "api/routes.py": routes, "api/gateway_chat.py": gateway}


def assert_rejected(tmp: Path, name: str, changed: dict[str, str], diagnostic: str) -> None:
    bundle = tmp / f"{name}.tar"
    archive(bundle, changed)
    result = run(bundle)
    assert result.returncode != 0, result.stdout
    assert diagnostic in result.stderr, result.stderr


with tempfile.TemporaryDirectory(prefix="roy-webui-archive-contract.") as tempdir:
    tmp = Path(tempdir)
    valid = tmp / "valid.tar"
    archive(valid, members())
    result = run(valid)
    assert result.returncode == 0, result.stderr
    assert "PASS" in result.stdout

    assert_rejected(tmp, "do-post-legacy", members(server=server_source.replace("self._handle_write(handle_post)", "self._handle_write(handle_get)")), "Handler.do_POST must directly call self._handle_write(handle_post)")
    assert_rejected(tmp, "write-ignores-route-func", members(server=server_source.replace("route_func(self, parsed)", "handle_post(self, parsed)")), "Handler._handle_write must execute route_func(self, parsed)")
    assert_rejected(tmp, "chat-start-legacy", members(routes=routes_source.replace("return _handle_chat_start(handler)", "return _run_agent_streaming()")), "api.routes /api/chat/start branch does not reach gateway-owned runner selection")
    assert_rejected(tmp, "gateway-disabled", members(gateway=gateway_source.replace('"api_server", ', "")), "api_server backend selector")
    assert_rejected(tmp, "gateway-legacy", members(gateway=gateway_source.replace('return "gateway"', 'return "legacy"')), "gateway backend must normalize accepted api_server mode to gateway")
    assert_rejected(tmp, "untrusted-url-resolver", members(gateway=gateway_source.replace('cfg.get("webui_gateway_base_url")', 'cfg.get("gateway_url")')), "gateway base URL resolution")
    assert_rejected(tmp, "untrusted-key-resolver", members(gateway=gateway_source.replace('source.get("API_SERVER_KEY")', 'source.get("GATEWAY_KEY")')), "gateway API key resolution")

print("roy-webui-api-server-archive-contract: PASS positive=1 negative=7")
