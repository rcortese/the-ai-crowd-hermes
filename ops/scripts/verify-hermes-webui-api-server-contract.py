#!/usr/bin/env python3
"""Fail-closed archive contract for Roy's WebUI api_server backend."""
from __future__ import annotations

import argparse
import ast
import sys
import tarfile
from typing import NoReturn

REQUIRED = ("server.py", "api/gateway_chat.py")
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
    if isinstance(node.func, ast.Name):
        return node.func.id
    return None


def function_definitions(module: ast.Module) -> dict[str, ast.FunctionDef | ast.AsyncFunctionDef]:
    return {
        node.name: node
        for node in module.body
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
    }


def calls_in(nodes: list[ast.stmt] | ast.AST) -> list[ast.Call]:
    roots = nodes if isinstance(nodes, list) else [nodes]
    result: list[ast.Call] = []
    for root in roots:
        for node in ast.walk(root):
            if isinstance(node, ast.Call):
                result.append(node)
    return result


def has_gateway_chat_import_and_activation(module: ast.Module) -> bool:
    module_aliases: set[str] = set()
    function_aliases: set[str] = set()
    for node in module.body:
        if isinstance(node, ast.Import):
            for imported in node.names:
                if imported.name == "api.gateway_chat":
                    module_aliases.add(imported.asname or "gateway_chat")
        elif isinstance(node, ast.ImportFrom) and node.module == "api":
            for imported in node.names:
                if imported.name == "gateway_chat":
                    module_aliases.add(imported.asname or "gateway_chat")
        elif isinstance(node, ast.ImportFrom) and node.module == "api.gateway_chat":
            for imported in node.names:
                function_aliases.add(imported.asname or imported.name)
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


def is_api_server_literal(node: ast.AST) -> bool:
    return isinstance(node, ast.Constant) and node.value == "api_server"


def is_selector_env_read(call: ast.Call) -> bool:
    return is_os_environ_get(call, ast.Name(id="_WEBUI_CHAT_BACKEND_ENV"))


def api_server_branch_calls(module: ast.Module) -> set[str]:
    """Return local functions entered by a selector's api_server branch."""
    functions = function_definitions(module)
    selector_names = {
        name
        for name, function in functions.items()
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
            # The branch must be selected by a function which reads the
            # deployment selector, not merely contain an unrelated literal.
            if not any(call_name(call) in selector_names for call in test_calls):
                continue
            starts.add(function.name)
            starts.update(
                name for call in calls_in(node.body) if (name := call_name(call)) is not None
            )
    return starts


def is_configured_transport_call(call: ast.Call) -> bool:
    if call_name(call) is None:
        return False
    arguments = list(call.args) + [keyword.value for keyword in call.keywords]
    helper_calls = {call_name(argument) for argument in arguments if isinstance(argument, ast.Call)}
    return {"_gateway_base_url", "_gateway_api_key"}.issubset(helper_calls)


def api_server_branch_reaches_configured_transport(module: ast.Module) -> bool:
    functions = function_definitions(module)
    pending = list(api_server_branch_calls(module))
    seen: set[str] = set()
    while pending:
        current = pending.pop()
        if current in seen or current not in functions:
            continue
        seen.add(current)
        for call in calls_in(functions[current].body):
            if is_configured_transport_call(call):
                return True
            if (name := call_name(call)) is not None and name in functions:
                pending.append(name)
    return False


def verify_execution_reachability(server: ast.Module, gateway: ast.Module) -> None:
    if not has_gateway_chat_import_and_activation(server):
        fail("server.py does not import and activate api.gateway_chat")
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
    verify_execution_reachability(parsed["server.py"], parsed["api/gateway_chat.py"])
    print("roy-webui-api-server-archive-contract: PASS required=server.py,api/gateway_chat.py")


if __name__ == "__main__":
    main()
