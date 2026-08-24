#!/usr/bin/env python3
"""Fail-closed structural archive contract for Roy's WebUI api_server path."""
from __future__ import annotations

import argparse
import ast
import sys
import tarfile
from typing import NoReturn

REQUIRED = ("server.py", "api/routes.py", "api/gateway_chat.py")
BACKEND_ENV = "HERMES_WEBUI_CHAT_BACKEND"
BASE_URL_ENV = "HERMES_WEBUI_GATEWAY_BASE_URL"
API_KEY_ENV = "HERMES_WEBUI_GATEWAY_API_KEY"
DEFAULT_URL = "http://127.0.0.1:8642"


def fail(message: str) -> NoReturn:
    print(f"roy-webui-api-server-archive-contract: RED {message}", file=sys.stderr)
    raise SystemExit(65)


def source_member(archive: tarfile.TarFile, name: str) -> str:
    try:
        member = archive.getmember(name)
        if not member.isfile():
            raise KeyError(name)
        stream = archive.extractfile(member)
        if stream is None:
            raise KeyError(name)
        return stream.read().decode("utf-8")
    except KeyError:
        fail(f"required archive member missing: {name}")
    except UnicodeDecodeError:
        fail(f"required archive member is not UTF-8 Python source: {name}")


def parse(name: str, source: str) -> ast.Module:
    try:
        return ast.parse(source, filename=name)
    except SyntaxError as exc:
        fail(f"compile failed for {name}: {exc.msg} at line {exc.lineno}")


def name(node: ast.AST, expected: str) -> bool:
    return isinstance(node, ast.Name) and node.id == expected


def call_name(call: ast.Call) -> str | None:
    return call.func.id if isinstance(call.func, ast.Name) else None


def calls(nodes: list[ast.stmt] | ast.AST) -> list[ast.Call]:
    roots = nodes if isinstance(nodes, list) else [nodes]
    result: list[ast.Call] = []
    def walk(node: ast.AST) -> None:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda, ast.ClassDef)):
            return
        if isinstance(node, ast.Call):
            result.append(node)
        for child in ast.iter_child_nodes(node):
            walk(child)
    for root in roots:
        walk(root)
    return result


def module_functions(module: ast.Module) -> dict[str, ast.FunctionDef | ast.AsyncFunctionDef]:
    return {node.name: node for node in module.body if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))}


def direct_self_call(function: ast.FunctionDef | ast.AsyncFunctionDef, method: str, argument: str) -> bool:
    for node in function.body:
        value = node.value if isinstance(node, (ast.Return, ast.Expr)) else None
        if not isinstance(value, ast.Call) or len(value.args) != 1 or value.keywords:
            continue
        if (isinstance(value.func, ast.Attribute) and isinstance(value.func.value, ast.Name)
                and value.func.value.id == "self" and value.func.attr == method and name(value.args[0], argument)):
            return True
    return False


def verify_server(server: ast.Module) -> None:
    handler = next((node for node in server.body if isinstance(node, ast.ClassDef) and node.name == "Handler"), None)
    if handler is None:
        fail("server.py missing Handler class")
    methods = {node.name: node for node in handler.body if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))}
    post = methods.get("do_POST")
    if post is None or not direct_self_call(post, "_handle_write", "handle_post"):
        fail("Handler.do_POST must directly call self._handle_write(handle_post)")
    write = methods.get("_handle_write")
    if write is None or [arg.arg for arg in write.args.args] != ["self", "route_func"]:
        fail("Handler._handle_write must execute route_func(self, parsed)")
    if not any(call_name(call) == "route_func" and len(call.args) == 2 and not call.keywords
               and name(call.args[0], "self") and name(call.args[1], "parsed") for call in calls(write.body)):
        fail("Handler._handle_write must execute route_func(self, parsed)")


def has_path_branch(function: ast.FunctionDef | ast.AsyncFunctionDef) -> list[ast.If]:
    return [node for node in ast.walk(function) if isinstance(node, ast.If)
            and any(isinstance(value, ast.Constant) and value.value == "/api/chat/start" for value in ast.walk(node.test))]


def called_local_names(function: ast.FunctionDef | ast.AsyncFunctionDef) -> set[str]:
    return {candidate for candidate in (call_name(call) for call in calls(function.body)) if candidate}


def gateway_owned_selection(function: ast.FunctionDef | ast.AsyncFunctionDef) -> bool:
    all_nodes = list(ast.walk(function))
    selector = any(call_name(call) == "webui_gateway_chat_enabled" for call in calls(function.body))
    runner = any(name(node, "_run_gateway_chat_streaming") for node in all_nodes)
    owned = any(isinstance(node, ast.IfExp) and name(node.body, "_run_gateway_chat_streaming") for node in all_nodes)
    return selector and runner and owned


def verify_routes(routes: ast.Module) -> None:
    functions = module_functions(routes)
    handler = functions.get("handle_post")
    if handler is None or [arg.arg for arg in handler.args.args] != ["handler", "parsed"]:
        fail("api.routes handle_post must accept handler, parsed")
    starts = has_path_branch(handler)
    if not starts:
        fail("api.routes missing /api/chat/start branch")
    frontier = set()
    for branch in starts:
        frontier.update(candidate for candidate in (call_name(call) for call in calls(branch.body)) if candidate)
    seen: set[str] = set()
    while frontier:
        candidate = frontier.pop()
        if candidate in seen or candidate not in functions:
            continue
        seen.add(candidate)
        current = functions[candidate]
        if gateway_owned_selection(current):
            return
        frontier.update(called_local_names(current) - seen)
    fail("api.routes /api/chat/start branch does not reach gateway-owned runner selection")


def constants(module: ast.Module, identifier: str) -> list[ast.Constant]:
    values = []
    for node in module.body:
        if isinstance(node, (ast.Assign, ast.AnnAssign)):
            targets = node.targets if isinstance(node, ast.Assign) else [node.target]
            if any(name(target, identifier) for target in targets) and isinstance(node.value, ast.Constant):
                values.append(node.value)
    return values


def all_constant_values(node: ast.AST) -> set[object]:
    return {item.value for item in ast.walk(node) if isinstance(item, ast.Constant)}


def verify_gateway(gateway: ast.Module) -> None:
    if not any(value.value == BACKEND_ENV for value in constants(gateway, "_WEBUI_CHAT_BACKEND_ENV")):
        fail("api_server backend selector missing HERMES_WEBUI_CHAT_BACKEND binding")
    selector = next((node.value for node in gateway.body if isinstance(node, (ast.Assign, ast.AnnAssign))
                     and any(name(target, "_GATEWAY_CHAT_BACKENDS") for target in (node.targets if isinstance(node, ast.Assign) else [node.target]))), None)
    if selector is None or "api_server" not in all_constant_values(selector):
        fail("api_server backend selector missing supported 'api_server' value")
    functions = module_functions(gateway)
    mode = functions.get("webui_chat_backend_mode")
    if mode is None or not any(isinstance(node, ast.Return) and isinstance(node.value, ast.Constant) and node.value.value == "gateway" for node in ast.walk(mode)):
        fail("gateway backend must normalize accepted api_server mode to gateway")
    if not any(value.value == BASE_URL_ENV for value in constants(gateway, "_WEBUI_GATEWAY_BASE_URL_ENV")):
        fail("gateway base URL resolution missing HERMES_WEBUI_GATEWAY_BASE_URL binding")
    base = functions.get("_gateway_base_url")
    if base is None or not {"webui_gateway_base_url", DEFAULT_URL}.issubset(all_constant_values(base)) or not any(isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == "rstrip" for node in ast.walk(base)):
        fail("gateway base URL resolution missing trusted environment/config/default normalization contract")
    if not any(value.value == API_KEY_ENV for value in constants(gateway, "_WEBUI_GATEWAY_API_KEY_ENV")):
        fail("gateway API key resolution missing HERMES_WEBUI_GATEWAY_API_KEY binding")
    key = functions.get("_gateway_api_key")
    if key is None or not {"API_SERVER_KEY", ""}.issubset(all_constant_values(key)):
        fail("gateway API key resolution must use trusted HERMES_WEBUI_GATEWAY_API_KEY -> API_SERVER_KEY chain")
    runner = functions.get("_run_gateway_chat_streaming")
    runner_calls = calls(runner.body) if runner else []
    if not any(call_name(call) == "_gateway_base_url" for call in runner_calls) or not any(call_name(call) == "_gateway_api_key" for call in runner_calls):
        fail("gateway transport must use trusted URL and key resolvers")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("archive", help="verified Git archive tarball")
    args = parser.parse_args()
    try:
        with tarfile.open(args.archive, "r:") as archive:
            parsed = {member: parse(member, source_member(archive, member)) for member in REQUIRED}
    except (tarfile.TarError, OSError) as exc:
        fail(f"cannot read WebUI archive: {exc}")
    verify_server(parsed["server.py"])
    verify_routes(parsed["api/routes.py"])
    verify_gateway(parsed["api/gateway_chat.py"])
    print("roy-webui-api-server-archive-contract: PASS required=server.py,api/routes.py,api/gateway_chat.py")


if __name__ == "__main__":
    main()
