#!/usr/bin/env python3
"""Fail-closed archive contract for Roy's WebUI api_server backend."""
from __future__ import annotations

import argparse
import ast
import sys
import tarfile
from typing import NoReturn

REQUIRED = ("server.py", "api/routes.py", "api/gateway_chat.py")
BACKEND_ENV = "HERMES_WEBUI_CHAT_BACKEND"
GATEWAY_BASE_URL_ENV = "HERMES_WEBUI_GATEWAY_BASE_URL"
GATEWAY_API_KEY_ENV = "HERMES_WEBUI_GATEWAY_API_KEY"
API_SERVER_KEY_ENV = "API_SERVER_KEY"
DEFAULT_GATEWAY_BASE_URL = "http://127.0.0.1:8642"


def fail(message: str) -> NoReturn:
    print(f"roy-webui-api-server-archive-contract: RED {message}", file=sys.stderr)
    raise SystemExit(65)


def source_member(archive: tarfile.TarFile, name: str) -> str:
    try:
        member = archive.getmember(name)
    except KeyError:
        fail(f"required archive member missing: {name}")
    if not member.isfile():
        fail(f"required archive member is not a regular file: {name}")
    extracted = archive.extractfile(member)
    if extracted is None:
        fail(f"required archive member cannot be read: {name}")
    try:
        return extracted.read().decode("utf-8")
    except UnicodeDecodeError:
        fail(f"required archive member is not UTF-8 Python source: {name}")


def parse_source(name: str, source: str) -> ast.Module:
    try:
        return ast.parse(source, filename=name)
    except SyntaxError as exc:
        fail(f"compile failed for {name}: {exc.msg} at line {exc.lineno}")


def assigned_value(module: ast.Module, name: str) -> ast.expr | None:
    for node in module.body:
        if isinstance(node, (ast.Assign, ast.AnnAssign)):
            targets = node.targets if isinstance(node, ast.Assign) else [node.target]
            if any(isinstance(target, ast.Name) and target.id == name for target in targets):
                return node.value
    return None


def is_os_environ_get(node: ast.expr, key: ast.expr, default: str | None = None) -> bool:
    if not isinstance(node, ast.Call) or len(node.args) < 1:
        return False
    function = node.func
    if not (
        isinstance(function, ast.Attribute)
        and function.attr == "get"
        and isinstance(function.value, ast.Attribute)
        and function.value.attr == "environ"
        and isinstance(function.value.value, ast.Name)
        and function.value.value.id == "os"
        and ast.dump(node.args[0]) == ast.dump(key)
    ):
        return False
    if default is None:
        return len(node.args) == 1
    return len(node.args) == 2 and isinstance(node.args[1], ast.Constant) and node.args[1].value == default


def function_return(module: ast.Module, name: str) -> ast.expr | None:
    for node in module.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == name:
            for statement in node.body:
                if isinstance(statement, ast.Return):
                    return statement.value
    return None


def flatten_or(node: ast.expr) -> list[ast.expr]:
    if isinstance(node, ast.BoolOp) and isinstance(node.op, ast.Or):
        result: list[ast.expr] = []
        for value in node.values:
            result.extend(flatten_or(value))
        return result
    return [node]


def verify_gateway_contract(module: ast.Module) -> None:
    backend_env = assigned_value(module, "_WEBUI_CHAT_BACKEND_ENV")
    if not (isinstance(backend_env, ast.Constant) and backend_env.value == BACKEND_ENV):
        fail("api_server backend selector missing HERMES_WEBUI_CHAT_BACKEND binding")

    selectors = assigned_value(module, "_GATEWAY_CHAT_BACKENDS")
    if not isinstance(selectors, (ast.Set, ast.List, ast.Tuple)) or not any(
        isinstance(item, ast.Constant) and item.value == "api_server" for item in selectors.elts
    ):
        fail("api_server backend selector missing supported 'api_server' value")

    gateway_base_env = assigned_value(module, "_WEBUI_GATEWAY_BASE_URL_ENV")
    if not (isinstance(gateway_base_env, ast.Constant) and gateway_base_env.value == GATEWAY_BASE_URL_ENV):
        fail("gateway base URL resolution missing HERMES_WEBUI_GATEWAY_BASE_URL binding")
    base_url = function_return(module, "_gateway_base_url")
    if not (
        isinstance(gateway_base_env, ast.expr)
        and base_url is not None
        and is_os_environ_get(base_url, ast.Name(id="_WEBUI_GATEWAY_BASE_URL_ENV"), DEFAULT_GATEWAY_BASE_URL)
    ):
        fail("gateway base URL resolution missing deployed environment/default contract")

    gateway_key_env = assigned_value(module, "_WEBUI_GATEWAY_API_KEY_ENV")
    if not (isinstance(gateway_key_env, ast.Constant) and gateway_key_env.value == GATEWAY_API_KEY_ENV):
        fail("gateway API key resolution missing HERMES_WEBUI_GATEWAY_API_KEY binding")
    api_key = function_return(module, "_gateway_api_key")
    expected_key_env = ast.Name(id="_WEBUI_GATEWAY_API_KEY_ENV")
    expected_fallback = ast.Constant(value=API_SERVER_KEY_ENV)
    values = flatten_or(api_key) if api_key is not None else []
    if not (
        len(values) == 3
        and is_os_environ_get(values[0], expected_key_env)
        and is_os_environ_get(values[1], expected_fallback)
        and isinstance(values[2], ast.Constant)
        and values[2].value == ""
    ):
        fail("API_SERVER_KEY fallback missing from gateway API key resolution")


def call_name(node: ast.Call) -> str | None:
    return node.func.id if isinstance(node.func, ast.Name) else None


def function_definitions(module: ast.Module) -> dict[str, ast.FunctionDef | ast.AsyncFunctionDef]:
    return {
        node.name: node
        for node in ast.walk(module)
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
    }


def calls_in(nodes: list[ast.stmt] | ast.AST) -> list[ast.Call]:
    roots = nodes if isinstance(nodes, list) else [nodes]
    return [node for root in roots for node in ast.walk(root) if isinstance(node, ast.Call)]


def import_aliases(module: ast.Module, imported_module: str) -> tuple[set[str], set[str]]:
    """Return module and direct-function aliases imported from *imported_module*."""
    module_aliases: set[str] = set()
    function_aliases: set[str] = set()
    package, _, leaf = imported_module.rpartition(".")
    for node in module.body:
        if isinstance(node, ast.Import):
            for imported in node.names:
                if imported.name == imported_module:
                    module_aliases.add(imported.asname or leaf)
        elif isinstance(node, ast.ImportFrom):
            if node.module == package:
                for imported in node.names:
                    if imported.name == leaf:
                        module_aliases.add(imported.asname or leaf)
            elif node.module == imported_module:
                for imported in node.names:
                    function_aliases.add(imported.asname or imported.name)
    return module_aliases, function_aliases


def has_gateway_chat_import_and_activation(module: ast.Module) -> bool:
    module_aliases, function_aliases = import_aliases(module, "api.gateway_chat")
    if not module_aliases and not function_aliases:
        return False
    return any(
        (
            isinstance(call.func, ast.Attribute)
            and isinstance(call.func.value, ast.Name)
            and call.func.value.id in module_aliases
        )
        or (isinstance(call.func, ast.Name) and call.func.id in function_aliases)
        for call in calls_in(module)
    )


def function_reaches(functions: dict[str, ast.FunctionDef | ast.AsyncFunctionDef], starts: set[str], predicate) -> bool:
    pending = list(starts)
    seen: set[str] = set()
    while pending:
        current = pending.pop()
        if current in seen or current not in functions:
            continue
        seen.add(current)
        function = functions[current]
        if predicate(function):
            return True
        pending.extend(
            name for call in calls_in(function.body)
            if (name := call_name(call)) in functions and name not in seen
        )
    return False


def function_has_chat_start_dispatch(function: ast.FunctionDef | ast.AsyncFunctionDef) -> bool:
    return any(isinstance(node, ast.Constant) and node.value == "/api/chat/start" for node in ast.walk(function))


def route_chat_dispatch_starts(routes: ast.Module) -> set[str]:
    functions = function_definitions(routes)
    starts: set[str] = set()
    for function in functions.values():
        if not function_has_chat_start_dispatch(function):
            continue
        starts.add(function.name)
        starts.update(name for call in calls_in(function.body) if (name := call_name(call)) in functions)
    return starts


def function_calls_imported(function: ast.FunctionDef | ast.AsyncFunctionDef, module_aliases: set[str], function_aliases: set[str]) -> bool:
    return any(
        (
            isinstance(call.func, ast.Attribute)
            and isinstance(call.func.value, ast.Name)
            and call.func.value.id in module_aliases
        )
        or (isinstance(call.func, ast.Name) and call.func.id in function_aliases)
        for call in calls_in(function.body)
    )


def server_public_dispatch_reaches_routes(server: ast.Module) -> bool:
    module_aliases, function_aliases = import_aliases(server, "api.routes")
    if not module_aliases and not function_aliases:
        return False
    functions = function_definitions(server)
    public_dispatchers = {
        name for name in functions
        if name in {"do_POST", "handle_post", "post"} or not name.startswith("_")
    }
    return function_reaches(
        functions,
        public_dispatchers,
        lambda function: function_calls_imported(function, module_aliases, function_aliases),
    )


def route_handler_reaches_gateway_runner(routes: ast.Module) -> bool:
    module_aliases, function_aliases = import_aliases(routes, "api.gateway_chat")
    if not module_aliases and not function_aliases:
        return False
    selector_names = {"webui_gateway_chat_enabled", "webui_chat_backend_mode"}
    runner_name = "_run_gateway_chat_streaming"

    def is_gateway_runner_selection(function: ast.FunctionDef | ast.AsyncFunctionDef) -> bool:
        selector_called = False
        runner_referenced = False
        for call in calls_in(function.body):
            if isinstance(call.func, ast.Attribute) and isinstance(call.func.value, ast.Name):
                selector_called |= call.func.value.id in module_aliases and call.func.attr in selector_names
                runner_referenced |= call.func.value.id in module_aliases and call.func.attr == runner_name
            elif isinstance(call.func, ast.Name):
                selector_called |= call.func.id in function_aliases and call.func.id in selector_names
                runner_referenced |= call.func.id in function_aliases and call.func.id == runner_name
        for node in ast.walk(function):
            if isinstance(node, ast.Name) and node.id in function_aliases and node.id == runner_name:
                runner_referenced = True
            elif (
                isinstance(node, ast.Attribute)
                and isinstance(node.value, ast.Name)
                and node.value.id in module_aliases
                and node.attr == runner_name
            ):
                runner_referenced = True
        return selector_called and runner_referenced

    starts = route_chat_dispatch_starts(routes)
    return bool(starts) and function_reaches(function_definitions(routes), starts, is_gateway_runner_selection)


def is_api_server_literal(node: ast.AST) -> bool:
    return isinstance(node, ast.Constant) and node.value == "api_server"


def is_selector_env_read(call: ast.Call) -> bool:
    return is_os_environ_get(call, ast.Name(id="_WEBUI_CHAT_BACKEND_ENV"))


def api_server_branch_calls(module: ast.Module) -> set[str]:
    """Return local functions entered by a selector's api_server branch."""
    functions = function_definitions(module)
    selector_names = {
        name for name, function in functions.items()
        if any(is_selector_env_read(call) for call in calls_in(function.body))
    }
    starts: set[str] = set()
    for function in functions.values():
        for node in ast.walk(function):
            if not isinstance(node, ast.If):
                continue
            test_calls = calls_in(node.test)
            if not test_calls or not any(is_api_server_literal(value) for value in ast.walk(node.test)):
                continue
            if not any(call_name(call) in selector_names for call in test_calls):
                continue
            starts.add(function.name)
            starts.update(name for call in calls_in(node.body) if (name := call_name(call)) is not None)
    return starts


def is_configured_transport_call(call: ast.Call) -> bool:
    if call_name(call) is None:
        return False
    arguments = list(call.args) + [keyword.value for keyword in call.keywords]
    helper_calls = {call_name(argument) for argument in arguments if isinstance(argument, ast.Call)}
    return {"_gateway_base_url", "_gateway_api_key"}.issubset(helper_calls)


def api_server_branch_reaches_configured_transport(module: ast.Module) -> bool:
    functions = function_definitions(module)
    return function_reaches(
        functions,
        api_server_branch_calls(module),
        lambda function: any(is_configured_transport_call(call) for call in calls_in(function.body)),
    )


def verify_execution_reachability(server: ast.Module, routes: ast.Module, gateway: ast.Module) -> None:
    if not has_gateway_chat_import_and_activation(server):
        fail("server.py does not import and activate api.gateway_chat")
    if not server_public_dispatch_reaches_routes(server):
        fail("server public chat dispatch does not reach api.routes chat handler")
    if not route_chat_dispatch_starts(routes):
        fail("api.routes public chat dispatch missing /api/chat/start handler")
    if not route_handler_reaches_gateway_runner(routes):
        fail("api.routes chat handler does not reach gateway selector/_run_gateway_chat_streaming")
    if not api_server_branch_calls(gateway):
        fail("api_server selector branch missing HERMES_WEBUI_CHAT_BACKEND execution path")
    if not api_server_branch_reaches_configured_transport(gateway):
        fail("api_server branch does not reach gateway transport consuming configured URL/key helpers")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("archive", help="verified Git archive tarball")
    args = parser.parse_args()
    source: dict[str, str] = {}
    try:
        with tarfile.open(args.archive, "r:") as archive:
            source = {name: source_member(archive, name) for name in REQUIRED}
    except (tarfile.TarError, OSError) as exc:
        fail(f"cannot read WebUI archive: {exc}")

    parsed = {name: parse_source(name, contents) for name, contents in source.items()}
    verify_gateway_contract(parsed["api/gateway_chat.py"])
    verify_execution_reachability(parsed["server.py"], parsed["api/routes.py"], parsed["api/gateway_chat.py"])
    print("roy-webui-api-server-archive-contract: PASS required=server.py,api/routes.py,api/gateway_chat.py")


if __name__ == "__main__":
    main()
