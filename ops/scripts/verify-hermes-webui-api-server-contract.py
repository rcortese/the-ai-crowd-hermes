#!/usr/bin/env python3
"""Fail-closed causal archive contract for Roy's WebUI api_server path."""
from __future__ import annotations

import argparse
import ast
import sys
import tarfile
from collections.abc import Iterable
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


def attribute_name(node: ast.AST) -> str | None:
    parts: list[str] = []
    while isinstance(node, ast.Attribute):
        parts.append(node.attr)
        node = node.value
    if isinstance(node, ast.Name):
        parts.append(node.id)
        return ".".join(reversed(parts))
    return None


def expression_calls(node: ast.AST | None) -> list[ast.Call]:
    """Calls in one expression, excluding a nested callable's body."""
    if node is None:
        return []
    found: list[ast.Call] = []

    def walk(current: ast.AST) -> None:
        if isinstance(current, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda, ast.ClassDef)):
            return
        if isinstance(current, ast.Call):
            found.append(current)
        for child in ast.iter_child_nodes(current):
            walk(child)

    walk(node)
    return found


def literal_bool(node: ast.AST) -> bool | None:
    if isinstance(node, ast.Constant) and isinstance(node.value, bool):
        return node.value
    return None


def effective_statements(statements: Iterable[ast.stmt]) -> list[ast.stmt]:
    """Return syntactically reachable statements; never descend into dead arms."""
    result: list[ast.stmt] = []
    for statement in statements:
        result.append(statement)
        if isinstance(statement, (ast.Return, ast.Raise, ast.Break, ast.Continue)):
            break
        if isinstance(statement, ast.If):
            known = literal_bool(statement.test)
            selected = statement.body if known is not False else statement.orelse
            result.extend(effective_statements(selected))
        elif isinstance(statement, (ast.With, ast.AsyncWith)):
            result.extend(effective_statements(statement.body))
        elif isinstance(statement, ast.Try):
            result.extend(effective_statements(statement.body))
            for handler in statement.handlers:
                result.extend(effective_statements(handler.body))
            result.extend(effective_statements(statement.orelse))
            result.extend(effective_statements(statement.finalbody))
    return result


def statement_calls(statement: ast.stmt) -> list[ast.Call]:
    """Calls owned by this statement, never by one of its nested bodies."""
    if isinstance(statement, ast.If):
        return expression_calls(statement.test)
    if isinstance(statement, (ast.With, ast.AsyncWith)):
        return [call for item in statement.items for call in expression_calls(item.context_expr)]
    if isinstance(statement, (ast.Try, ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
        return []
    return expression_calls(statement)


def reachable_calls(function: ast.FunctionDef | ast.AsyncFunctionDef) -> list[ast.Call]:
    return [call for statement in effective_statements(function.body) for call in statement_calls(statement)]


def module_functions(module: ast.Module) -> dict[str, ast.FunctionDef | ast.AsyncFunctionDef]:
    return {node.name: node for node in module.body if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))}


def direct_self_call(function: ast.FunctionDef | ast.AsyncFunctionDef, method: str, argument: str) -> bool:
    """Require the actual method body, not a nested/dead statement, to call it."""
    for statement in function.body:
        value = statement.value if isinstance(statement, (ast.Return, ast.Expr)) else None
        if not isinstance(value, ast.Call) or len(value.args) != 1 or value.keywords:
            if isinstance(statement, (ast.Return, ast.Raise)):
                return False
            continue
        if (isinstance(value.func, ast.Attribute) and name(value.func.value, "self")
                and value.func.attr == method and name(value.args[0], argument)):
            return True
        if isinstance(statement, (ast.Return, ast.Raise)):
            return False
    return False


def assigned_name(statement: ast.stmt) -> str | None:
    if isinstance(statement, (ast.Assign, ast.AnnAssign)):
        targets = statement.targets if isinstance(statement, ast.Assign) else [statement.target]
        if len(targets) == 1 and isinstance(targets[0], ast.Name):
            return targets[0].id
    return None


def assigned_value(statement: ast.stmt) -> ast.AST | None:
    return statement.value if isinstance(statement, (ast.Assign, ast.AnnAssign)) else None


def effective_bindings(function: ast.FunctionDef | ast.AsyncFunctionDef) -> dict[str, ast.AST]:
    return {target: value for statement in effective_statements(function.body)
            if (target := assigned_name(statement)) is not None and (value := assigned_value(statement)) is not None}


def expr_depends_on(node: ast.AST, roots: set[str], bindings: dict[str, ast.AST], seen: set[str] | None = None) -> bool:
    seen = set() if seen is None else seen
    if isinstance(node, ast.Name):
        if node.id in roots:
            return True
        if node.id in seen or node.id not in bindings:
            return False
        return expr_depends_on(bindings[node.id], roots, bindings, seen | {node.id})
    return any(expr_depends_on(child, roots, bindings, seen) for child in ast.iter_child_nodes(node))


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
    bindings = effective_bindings(write)
    if not any(call_name(call) == "route_func" and len(call.args) == 2 and not call.keywords
               and name(call.args[0], "self") and name(call.args[1], "parsed")
               and "parsed" in bindings for call in reachable_calls(write)):
        fail("Handler._handle_write must execute route_func(self, parsed)")


def is_chat_start_test(node: ast.AST) -> bool:
    return (isinstance(node, ast.Compare) and len(node.ops) == 1 and isinstance(node.ops[0], ast.Eq)
            and any(isinstance(value, ast.Constant) and value.value == "/api/chat/start" for value in node.comparators))


def ordered_statement_states(function: ast.FunctionDef | ast.AsyncFunctionDef) -> list[tuple[ast.stmt, dict[str, ast.AST]]]:
    """Record each reachable statement with bindings available *at that point*.

    The verifier is deliberately conservative for non-literal branches: every
    feasible local branch reaches a sink independently.  A later assignment is
    never allowed to change the state used for an earlier sink.
    """
    events: list[tuple[ast.stmt, dict[str, ast.AST]]] = []

    def block(statements: Iterable[ast.stmt], states: list[dict[str, ast.AST]]) -> list[dict[str, ast.AST]]:
        active = states
        for statement in statements:
            following: list[dict[str, ast.AST]] = []
            for state in active:
                events.append((statement, state))
                if isinstance(statement, ast.If):
                    known = literal_bool(statement.test)
                    branches = (statement.body,) if known is True else (statement.orelse,) if known is False else (statement.body, statement.orelse)
                    following.extend(result for branch in branches for result in block(branch, [dict(state)]))
                elif isinstance(statement, (ast.With, ast.AsyncWith)):
                    following.extend(block(statement.body, [dict(state)]))
                elif isinstance(statement, ast.Try):
                    following.extend(block(statement.body, [dict(state)]))
                    for handler in statement.handlers:
                        following.extend(block(handler.body, [dict(state)]))
                    if statement.orelse:
                        following.extend(block(statement.orelse, [dict(state)]))
                    if statement.finalbody:
                        following = block(statement.finalbody, following)
                elif isinstance(statement, (ast.Return, ast.Raise, ast.Break, ast.Continue)):
                    continue
                else:
                    next_state = dict(state)
                    if (target := assigned_name(statement)) is not None and (value := assigned_value(statement)) is not None:
                        next_state[target] = value
                    following.append(next_state)
            active = following
        return active

    block(function.body, [{}])
    return events


def resolved_expression(node: ast.AST, state: dict[str, ast.AST], seen: set[str] | None = None) -> ast.AST:
    seen = set() if seen is None else seen
    if isinstance(node, ast.Name) and node.id in state and node.id not in seen:
        return resolved_expression(state[node.id], state, seen | {node.id})
    return node


def expression_uses_resolver(node: ast.AST, resolver: str, state: dict[str, ast.AST]) -> bool:
    roots = {target for target, value in state.items()
             if any(call_name(call) == resolver for call in expression_calls(value))}
    return (any(call_name(call) == resolver for call in expression_calls(node))
            or bool(roots and expr_depends_on(node, roots, state)))


def gateway_owned_selection(function: ast.FunctionDef | ast.AsyncFunctionDef) -> bool:
    """Require every reachable Thread sink to select the gateway runner."""
    thread_sinks: list[bool] = []
    for statement, state in ordered_statement_states(function):
        for call in statement_calls(statement):
            if attribute_name(call.func) != "threading.Thread":
                continue
            target = next((keyword.value for keyword in call.keywords if keyword.arg == "target"), None)
            selected = resolved_expression(target, state) if target is not None else None
            thread_sinks.append(isinstance(selected, ast.IfExp)
                                and name(selected.body, "_run_gateway_chat_streaming")
                                and expression_uses_resolver(selected.test, "webui_gateway_chat_enabled", state))
    return bool(thread_sinks) and all(thread_sinks)


def verify_routes(routes: ast.Module) -> None:
    functions = module_functions(routes)
    handler = functions.get("handle_post")
    if handler is None or [arg.arg for arg in handler.args.args] != ["handler", "parsed"]:
        fail("api.routes handle_post must accept handler, parsed")
    starts = [statement for statement in effective_statements(handler.body)
              if isinstance(statement, ast.If) and is_chat_start_test(statement.test)]
    if not starts:
        fail("api.routes missing /api/chat/start branch")
    frontier = {call_name(call) for branch in starts for statement in effective_statements(branch.body)
                for call in statement_calls(statement) if call_name(call)}
    seen: set[str] = set()
    while frontier:
        candidate = frontier.pop()
        if candidate in seen or candidate not in functions:
            continue
        seen.add(candidate)
        current = functions[candidate]
        if gateway_owned_selection(current):
            return
        frontier.update(call_name(call) for call in reachable_calls(current) if call_name(call) and call_name(call) not in seen)
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


def is_request_call(call: ast.Call) -> bool:
    return attribute_name(call.func) == "urllib.request.Request"


def is_urlopen_call(call: ast.Call) -> bool:
    return attribute_name(call.func) == "urllib.request.urlopen"


def trusted_request_expression(node: ast.AST, state: dict[str, ast.AST], seen: set[str] | None = None) -> bool:
    """Check the Request construction reached by this urlopen argument now."""
    seen = set() if seen is None else seen
    if isinstance(node, ast.Name) and node.id in state and node.id not in seen:
        return trusted_request_expression(state[node.id], state, seen | {node.id})
    if not isinstance(node, ast.Call) or not is_request_call(node) or not node.args:
        return False
    headers = next((keyword.value for keyword in node.keywords if keyword.arg == "headers"), None)
    return (headers is not None
            and expression_uses_resolver(node.args[0], "_gateway_base_url", state)
            and expression_uses_resolver(headers, "_gateway_api_key", state))


def request_uses_trusted_transport(runner: ast.FunctionDef | ast.AsyncFunctionDef) -> bool:
    """Require ordered, local trust proof at every Request and urlopen sink."""
    request_sinks: list[bool] = []
    urlopen_sinks: list[bool] = []
    for statement, state in ordered_statement_states(runner):
        for call in statement_calls(statement):
            if is_request_call(call):
                request_sinks.append(trusted_request_expression(call, state))
            elif is_urlopen_call(call):
                urlopen_sinks.append(bool(call.args) and trusted_request_expression(call.args[0], state))
    return bool(request_sinks) and bool(urlopen_sinks) and all(request_sinks) and all(urlopen_sinks)


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
    if runner is None or not request_uses_trusted_transport(runner):
        fail("gateway transport must execute with trusted URL and key resolver results")


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
