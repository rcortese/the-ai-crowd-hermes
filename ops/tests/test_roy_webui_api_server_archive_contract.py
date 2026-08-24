#!/usr/bin/env python3
"""Causal source-archive contract for Roy's WebUI api_server backend."""
from __future__ import annotations

import ast
import io
import os
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

# The deployment layer retains its explicit outer-key -> archive-key bridge.
# The archived resolver also has the immutable API_SERVER_KEY compatibility
# fallback required by the verified WebUI archive.
def require_roy_webui_supervisor_contract(config: str) -> None:
    for literal in (
        'HERMES_WEBUI_CHAT_BACKEND="api_server"',
        'HERMES_WEBUI_GATEWAY_BASE_URL="http://roy:8645"',
        'HERMES_WEBUI_GATEWAY_API_KEY="%(ENV_API_SERVER_KEY)s"',
    ):
        assert literal in config


require_roy_webui_supervisor_contract(supervisor)

# The explicit deployment bridge remains required even though the archive also
# retains its verified API_SERVER_KEY compatibility fallback.
without_api_server_key_mapping = supervisor.replace(
    'HERMES_WEBUI_GATEWAY_API_KEY="%(ENV_API_SERVER_KEY)s"',
    'HERMES_WEBUI_GATEWAY_API_KEY=""',
    1,
)
try:
    require_roy_webui_supervisor_contract(without_api_server_key_mapping)
except AssertionError:
    pass
else:
    raise AssertionError("Roy supervisor contract accepted missing API_SERVER_KEY mapping")


def local_gateway_api_key(gateway: str, environ: dict[str, str]) -> str:
    """Execute only the versioned archive resolver against a supplied env."""
    module = ast.parse(gateway, filename="api/gateway_chat.py")
    body = [
        node
        for node in module.body
        if (
            isinstance(node, (ast.Assign, ast.AnnAssign))
            and any(
                isinstance(target, ast.Name) and target.id == "_WEBUI_GATEWAY_API_KEY_ENV"
                for target in (node.targets if isinstance(node, ast.Assign) else [node.target])
            )
        )
        or isinstance(node, ast.FunctionDef) and node.name == "_gateway_api_key"
    ]
    assert len(body) == 2, "versioned gateway key resolver is unavailable"
    namespace = {"os": os}
    exec(compile(ast.Module(body=body, type_ignores=[]), "api/gateway_chat.py", "exec"), namespace)
    return namespace["_gateway_api_key"](environ)


def require_versioned_archive_key_contract(gateway: str) -> None:
    assert local_gateway_api_key(gateway, {"API_SERVER_KEY": "outer-only"}) == "outer-only"
    assert local_gateway_api_key(
        gateway,
        {
            "HERMES_WEBUI_GATEWAY_API_KEY": "webui-specific",
            "API_SERVER_KEY": "outer-only",
        },
    ) == "webui-specific"


versioned_gateway_source = (root / "ops/webui-overrides/api/gateway_chat.py").read_text(encoding="utf-8")
require_versioned_archive_key_contract(versioned_gateway_source)


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
def _gateway_base_url(config_data, environ: dict[str, str] | None = None):
    source = os.environ if environ is None else environ
    cfg = config_data if isinstance(config_data, dict) else {}
    raw = str(
        source.get(_WEBUI_GATEWAY_BASE_URL_ENV)
        or cfg.get("webui_gateway_base_url")
        or "http://127.0.0.1:8642"
    ).strip()
    return raw.rstrip("/") or "http://127.0.0.1:8642"
def _gateway_api_key(environ: dict[str, str] | None = None):
    source = os.environ if environ is None else environ
    return str(
        source.get(_WEBUI_GATEWAY_API_KEY_ENV)
        or source.get("API_SERVER_KEY")
        or ""
    ).strip()
def _gateway_transport(base_url, api_key):
    return (base_url, api_key)
def _run_gateway_chat_streaming(config_data):
    if webui_chat_backend_mode() == "api_server":
        return _gateway_transport(_gateway_base_url(config_data), _gateway_api_key())
    return None
'''

routes_source = '''\
from api.gateway_chat import _run_gateway_chat_streaming, webui_gateway_chat_enabled

def handle_post(config_data):
    path = "/api/chat/start"
    if path == "/api/chat/start" and webui_gateway_chat_enabled():
        return _run_gateway_chat_streaming(config_data)
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

    # This resolver is the trusted archived-WebUI shape: an explicit
    # environment override wins over the static WebUI config, then both paths
    # retain the deployed fallback and trailing-slash normalization.
    assert_rejected(
        "gateway-base-url-without-environment-override",
        members(gateway=gateway_source.replace(
            "source.get(_WEBUI_GATEWAY_BASE_URL_ENV)\n        or ",
            "None\n        or ",
        )),
        "gateway base URL resolution",
        tmp,
    )
    assert_rejected(
        "gateway-base-url-without-config-key-path",
        members(gateway=gateway_source.replace(
            'cfg.get("webui_gateway_base_url")',
            'cfg.get("gateway_base_url")',
        )),
        "gateway base URL resolution",
        tmp,
    )
    assert_rejected(
        "gateway-base-url-without-fallback",
        members(gateway=gateway_source.replace(
            '        or "http://127.0.0.1:8642"\n    ).strip()',
            "    ).strip()",
        )),
        "gateway base URL resolution",
        tmp,
    )
    assert_rejected(
        "gateway-base-url-without-normalization",
        members(gateway=gateway_source.replace(
            'return raw.rstrip("/") or "http://127.0.0.1:8642"',
            "return raw",
        )),
        "gateway base URL resolution",
        tmp,
    )
    assert_rejected(
        "gateway-base-url-optional-config-input",
        members(gateway=gateway_source.replace(
            "def _gateway_base_url(config_data, environ: dict[str, str] | None = None):",
            "def _gateway_base_url(config_data=None, environ: dict[str, str] | None = None):",
        )),
        "gateway base URL resolution",
        tmp,
    )
    assert_rejected(
        "gateway-base-url-reordered-parameters",
        members(gateway=gateway_source.replace(
            "def _gateway_base_url(config_data, environ: dict[str, str] | None = None):",
            "def _gateway_base_url(environ, config_data=None):",
        )),
        "gateway base URL resolution",
        tmp,
    )
    assert_rejected(
        "gateway-base-url-allows-caller-url",
        members(gateway=gateway_source.replace(
            "def _gateway_base_url(config_data, environ: dict[str, str] | None = None):",
            "def _gateway_base_url(config_data, environ: dict[str, str] | None = None, user_base_url=None):",
        ).replace(
            "source.get(_WEBUI_GATEWAY_BASE_URL_ENV)",
            "user_base_url or source.get(_WEBUI_GATEWAY_BASE_URL_ENV)",
        )),
        "gateway base URL resolution",
        tmp,
    )

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
    # The positive fixture mirrors the archived resolver shape exactly: source
    # is environment-backed, HERMES wins, API_SERVER_KEY is its compatibility
    # fallback, and an empty literal closes the chain.
    assert_rejected(
        "archive-api-key-removed-hermes-key",
        members(gateway=gateway_source.replace(
            'source.get(_WEBUI_GATEWAY_API_KEY_ENV)\n        or source.get("API_SERVER_KEY")',
            'source.get("API_SERVER_KEY")\n        or source.get("API_SERVER_KEY")',
        )),
        "gateway API key resolution",
        tmp,
    )
    assert_rejected(
        "archive-api-key-removed-api-server-fallback",
        members(gateway=gateway_source.replace(
            '        or source.get("API_SERVER_KEY")\n',
            "",
        )),
        "gateway API key resolution",
        tmp,
    )
    assert_rejected(
        "archive-api-key-removed-empty-fallback",
        members(gateway=gateway_source.replace(
            '        or ""\n',
            "",
        )),
        "gateway API key resolution",
        tmp,
    )
    assert_rejected(
        "archive-api-key-caller-controlled-input",
        members(gateway=gateway_source.replace(
            "def _gateway_api_key(environ: dict[str, str] | None = None):",
            "def _gateway_api_key(environ: dict[str, str] | None = None, user_api_key=None):",
        ).replace(
            "source.get(_WEBUI_GATEWAY_API_KEY_ENV)",
            "user_api_key or source.get(_WEBUI_GATEWAY_API_KEY_ENV)",
        )),
        "gateway API key resolution",
        tmp,
    )
    assert_rejected(
        "archive-api-key-reversed-precedence",
        members(gateway=gateway_source.replace(
            'source.get(_WEBUI_GATEWAY_API_KEY_ENV)\n        or source.get("API_SERVER_KEY")',
            'source.get("API_SERVER_KEY")\n        or source.get(_WEBUI_GATEWAY_API_KEY_ENV)',
        )),
        "gateway API key resolution",
        tmp,
    )
    # Keep selector/constants/helper declarations byte-for-byte intact, but
    # sever the active api_server branch from the configured transport.
    assert_rejected(
        "api-server-disconnected-from-transport",
        members(gateway=gateway_source.replace(
            "return _gateway_transport(_gateway_base_url(config_data), _gateway_api_key())",
            "return None",
        )),
        "api_server transport must call _gateway_base_url with exactly one route/handler configuration argument",
        tmp,
    )
    # A configured transport hidden in an uncalled nested gateway helper is
    # not the active api_server control-flow path.
    nested_gateway_transport = gateway_source.replace(
        "    if webui_chat_backend_mode() == \"api_server\":\n        return _gateway_transport(_gateway_base_url(config_data), _gateway_api_key())\n    return None",
        "    def nested_api_server_transport():\n        if webui_chat_backend_mode() == \"api_server\":\n            return _gateway_transport(_gateway_base_url(config_data), _gateway_api_key())\n    return None",
    )
    assert_rejected(
        "api-server-nested-gateway-helper",
        members(gateway=nested_gateway_transport),
        "api_server transport must call _gateway_base_url with exactly one route/handler configuration argument",
        tmp,
    )
    # A literal HTTPServer do_POST entrypoint is mandatory; legacy aliases
    # cannot be used as a fallback entrypoint.
    missing_do_post_with_handle_post = server_source.replace("def do_POST():", "def handle_post():")
    assert_rejected(
        "missing-literal-do-post-with-handle-post-fallback",
        members(server=missing_do_post_with_handle_post),
        "server.py missing literal do_POST entrypoint",
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
    # Calls hidden in an uncalled nested helper are not request dispatch.
    do_post_legacy_with_nested_routes_helper = '''\
from api import gateway_chat, routes

def do_POST():
    def nested_routes_helper():
        return routes.handle_post()
    return _legacy_direct_chat()

def _legacy_direct_chat():
    return None

def warm_gateway():
    return gateway_chat.webui_gateway_chat_enabled()
'''
    assert_rejected(
        "do-post-legacy-nested-routes-helper",
        members(server=do_post_legacy_with_nested_routes_helper),
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
    # Calls hidden in an uncalled nested function inside handle_post must not
    # make its direct /api/chat/start dispatch look gateway-backed.
    chat_start_legacy_with_nested_gateway_helper = '''\
from api.gateway_chat import _run_gateway_chat_streaming, webui_gateway_chat_enabled

def handle_post():
    path = "/api/chat/start"
    def nested_gateway_helper():
        if webui_gateway_chat_enabled():
            return _run_gateway_chat_streaming()
    if path == "/api/chat/start":
        return _run_legacy_chat_streaming()
    return None

def _run_legacy_chat_streaming():
    return None
'''
    assert_rejected(
        "chat-start-legacy-nested-gateway-helper",
        members(routes=chat_start_legacy_with_nested_gateway_helper),
        "api.routes /api/chat/start branch does not directly call gateway selector/runner",
        tmp,
    )
    # A transport hidden in another branch must not satisfy the api_server
    # branch: that branch itself must consume both configured gateway helpers.
    api_server_legacy_with_else_transport = gateway_source.replace(
        "return _gateway_transport(_gateway_base_url(config_data), _gateway_api_key())\n    return None",
        "return None\n    return _gateway_transport(_gateway_base_url(config_data), _gateway_api_key())",
    )
    assert_rejected(
        "api-server-legacy-else-transport",
        members(gateway=api_server_legacy_with_else_transport),
        "api_server transport must call _gateway_base_url with exactly one route/handler configuration argument",
        tmp,
    )

    # The active api_server transport must carry the handler's configuration
    # through the gateway runner; a required resolver declaration alone is not
    # evidence that the configured value reaches the transport.
    assert_rejected(
        "api-server-zero-argument-base-url-call",
        members(gateway=gateway_source.replace(
            "_gateway_base_url(config_data)",
            "_gateway_base_url()",
            1,
        )),
        "api_server transport must call _gateway_base_url with exactly one route/handler configuration argument",
        tmp,
    )
    assert_rejected(
        "api-server-unrelated-base-url-config",
        members(gateway=gateway_source.replace(
            "def _run_gateway_chat_streaming(config_data):",
            "def _run_gateway_chat_streaming(config_data):\n    unrelated_config = {}",
        ).replace(
            "_gateway_base_url(config_data)",
            "_gateway_base_url(unrelated_config)",
            1,
        )),
        "api_server transport must call _gateway_base_url with exactly one route/handler configuration argument",
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

print("roy-webui-api-server-archive-contract: PASS positive=2 negative=25")
