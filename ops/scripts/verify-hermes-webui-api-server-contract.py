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
    """Return only module-level functions; nested helpers are not entrypoints."""
    return {
        node.name: node
        for node in module.body
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
    }


_NESTED_EXECUTION_BOUNDARIES = (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda, ast.ClassDef)


def executable_nodes(nodes: list[ast.stmt] | ast.AST):
    """Walk active control flow without entering deferred nested bodies."""
    roots = nodes if isinstance(nodes, list) else [nodes]

    def visit(node: ast.AST):
        if isinstance(node, _NESTED_EXECUTION_BOUNDARIES):
            return
        yield node
        for child in ast.iter_child_nodes(node):
            yield from visit(child)

    for root in roots:
        if not isinstance(root, _NESTED_EXECUTION_BOUNDARIES):
            yield from visit(root)


def calls_in(nodes: list[ast.stmt] | ast.AST) -> list[ast.Call]:
    return [node for node in executable_nodes(nodes) if isinstance(node, ast.Call)]


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


def imported_function_aliases(module: ast.Module, imported_module: str, function_name: str) -> tuple[set[str], set[str]]:
    """Return aliases that name one exact imported function, not its siblings."""
    module_aliases, _ = import_aliases(module, imported_module)
    direct_aliases: set[str] = set()
    for node in module.body:
        if isinstance(node, ast.ImportFrom) and node.module == imported_module:
            for imported in node.names:
                if imported.name == function_name:
                    direct_aliases.add(imported.asname or imported.name)
    return module_aliases, direct_aliases


def calls_imported_function(call: ast.Call, module_aliases: set[str], direct_aliases: set[str], function_name: str) -> bool:
    return (
        isinstance(call.func, ast.Attribute)
        and isinstance(call.func.value, ast.Name)
        and call.func.value.id in module_aliases
        and call.func.attr == function_name
    ) or (isinstance(call.func, ast.Name) and call.func.id in direct_aliases)


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
        for function in function_definitions(module).values()
        for call in calls_in(function.body)
    )


def server_post_handler(server: ast.Module) -> ast.FunctionDef | ast.AsyncFunctionDef:
    # HTTPServer dispatches this exact, literal entrypoint.  Do not accept
    # compatibility aliases such as handle_post/post as a fallback.
    handler = function_definitions(server).get("do_POST")
    if handler is None:
        fail("server.py missing literal do_POST entrypoint")
    return handler


def server_post_handler_reaches_routes(server: ast.Module) -> bool:
    module_aliases, direct_aliases = imported_function_aliases(server, "api.routes", "handle_post")
    if not module_aliases and not direct_aliases:
        return False
    handler = server_post_handler(server)
    return any(
        calls_imported_function(call, module_aliases, direct_aliases, "handle_post")
        for call in direct_calls_in(handler.body)
    )


def direct_calls_in(statements: list[ast.stmt]) -> list[ast.Call]:
    """Calls evaluated by immediate branch statements, excluding nested branches/helpers."""
    calls: list[ast.Call] = []
    for statement in statements:
        value: ast.expr | None = None
        if isinstance(statement, ast.Return):
            value = statement.value
        elif isinstance(statement, ast.Expr):
            value = statement.value
        elif isinstance(statement, (ast.Assign, ast.AnnAssign)):
            value = statement.value
        if isinstance(value, ast.Call):
            calls.append(value)
    return calls


def is_chat_start_branch(node: ast.If) -> bool:
    return any(isinstance(value, ast.Constant) and value.value == "/api/chat/start" for value in ast.walk(node.test))


def route_handler_directly_calls_gateway(routes: ast.Module) -> bool:
    module_aliases, selector_aliases = imported_function_aliases(
        routes, "api.gateway_chat", "webui_gateway_chat_enabled"
    )
    _, mode_aliases = imported_function_aliases(routes, "api.gateway_chat", "webui_chat_backend_mode")
    _, runner_aliases = imported_function_aliases(routes, "api.gateway_chat", "_run_gateway_chat_streaming")
    if not module_aliases and not (selector_aliases or mode_aliases or runner_aliases):
        return False
    handler = function_definitions(routes).get("handle_post")
    if handler is None:
        return False
    for branch in (node for node in executable_nodes(handler.body) if isinstance(node, ast.If) and is_chat_start_branch(node)):
        for call in direct_calls_in(branch.body):
            if calls_imported_function(call, module_aliases, selector_aliases, "webui_gateway_chat_enabled"):
                return True
            if calls_imported_function(call, module_aliases, mode_aliases, "webui_chat_backend_mode"):
                return True
            if calls_imported_function(call, module_aliases, runner_aliases, "_run_gateway_chat_streaming"):
                return True
    return False


def is_api_server_literal(node: ast.AST) -> bool:
    return isinstance(node, ast.Constant) and node.value == "api_server"


def is_selector_env_read(call: ast.Call) -> bool:
    return is_os_environ_get(call, ast.Name(id="_WEBUI_CHAT_BACKEND_ENV"))


def is_configured_transport_call(call: ast.Call) -> bool:
    if call_name(call) is None:
        return False
    arguments = list(call.args) + [keyword.value for keyword in call.keywords]
    helper_calls = {call_name(argument) for argument in arguments if isinstance(argument, ast.Call)}
    return {"_gateway_base_url", "_gateway_api_key"}.issubset(helper_calls)


def api_server_branch_directly_calls_configured_transport(module: ast.Module) -> bool:
    functions = function_definitions(module)
    selector_names = {
        name for name, function in functions.items()
        if any(is_selector_env_read(call) for call in calls_in(function.body))
    }
    for function in functions.values():
        for branch in (node for node in executable_nodes(function.body) if isinstance(node, ast.If)):
            test_calls = calls_in(branch.test)
            if not any(is_api_server_literal(value) for value in ast.walk(branch.test)):
                continue
            if not any(call_name(call) in selector_names for call in test_calls):
                continue
            if any(is_configured_transport_call(call) for call in direct_calls_in(branch.body)):
                return True
    return False


def verify_execution_reachability(server: ast.Module, routes: ast.Module, gateway: ast.Module) -> None:
    if not has_gateway_chat_import_and_activation(server):
        fail("server.py does not import and activate api.gateway_chat")
    if not server_post_handler_reaches_routes(server):
        fail("server do_POST does not reach api.routes.handle_post")
    if not route_handler_directly_calls_gateway(routes):
        fail("api.routes /api/chat/start branch does not directly call gateway selector/runner")
    if not api_server_branch_directly_calls_configured_transport(gateway):
        fail("api_server branch does not directly call gateway transport consuming configured URL/key helpers")


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
