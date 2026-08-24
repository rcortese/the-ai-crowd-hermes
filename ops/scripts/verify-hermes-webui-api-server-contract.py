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


def function_definition(module: ast.Module, name: str) -> ast.FunctionDef | ast.AsyncFunctionDef | None:
    for node in module.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == name:
            return node
    return None


def is_name(node: ast.AST, name: str) -> bool:
    return isinstance(node, ast.Name) and node.id == name


def is_none(node: ast.AST) -> bool:
    return isinstance(node, ast.Constant) and node.value is None


def is_dict_type(node: ast.AST) -> bool:
    return is_name(node, "dict")


def is_mapping_get(node: ast.AST, mapping: str, key: ast.AST) -> bool:
    return (
        isinstance(node, ast.Call)
        and not node.keywords
        and len(node.args) == 1
        and isinstance(node.func, ast.Attribute)
        and node.func.attr == "get"
        and is_name(node.func.value, mapping)
        and ast.dump(node.args[0]) == ast.dump(key)
    )


def is_gateway_base_url_resolution(function: ast.FunctionDef | ast.AsyncFunctionDef | None) -> bool:
    """Accept only the trusted env -> config -> normalized fallback resolver."""
    if function is None:
        return False
    arguments = function.args
    if (
        arguments.posonlyargs
        or arguments.vararg is not None
        or arguments.kwarg is not None
        or [argument.arg for argument in arguments.args] != ["config_data", "environ"]
        # The verified archive deliberately accepts omitted config_data and
        # environ, then constrains their use to the trusted resolver body.
        # ast.arguments.defaults aligns to the final positional parameters.
        or len(arguments.defaults) != 2
        or not all(is_none(default) for default in arguments.defaults)
    ):
        return False
    if len(function.body) != 4:
        return False
    source_assignment, config_assignment, raw_assignment, returned = function.body
    if not (
        isinstance(source_assignment, ast.Assign)
        and len(source_assignment.targets) == 1
        and is_name(source_assignment.targets[0], "source")
        and isinstance(source_assignment.value, ast.IfExp)
        and isinstance(source_assignment.value.test, ast.Compare)
        and len(source_assignment.value.test.ops) == 1
        and isinstance(source_assignment.value.test.ops[0], ast.Is)
        and len(source_assignment.value.test.comparators) == 1
        and is_name(source_assignment.value.test.left, "environ")
        and is_none(source_assignment.value.test.comparators[0])
        and isinstance(source_assignment.value.body, ast.Attribute)
        and source_assignment.value.body.attr == "environ"
        and is_name(source_assignment.value.body.value, "os")
        and is_name(source_assignment.value.orelse, "environ")
    ):
        return False
    if not (
        isinstance(config_assignment, ast.Assign)
        and len(config_assignment.targets) == 1
        and is_name(config_assignment.targets[0], "cfg")
        and isinstance(config_assignment.value, ast.IfExp)
        and isinstance(config_assignment.value.test, ast.Call)
        and is_name(config_assignment.value.test.func, "isinstance")
        and len(config_assignment.value.test.args) == 2
        and is_name(config_assignment.value.test.args[0], "config_data")
        and is_dict_type(config_assignment.value.test.args[1])
        and is_name(config_assignment.value.body, "config_data")
        and isinstance(config_assignment.value.orelse, ast.Dict)
        and not config_assignment.value.orelse.keys
        and not config_assignment.value.orelse.values
    ):
        return False
    if not (
        isinstance(raw_assignment, ast.Assign)
        and len(raw_assignment.targets) == 1
        and is_name(raw_assignment.targets[0], "raw")
        and isinstance(raw_assignment.value, ast.Call)
        and not raw_assignment.value.args
        and not raw_assignment.value.keywords
        and isinstance(raw_assignment.value.func, ast.Attribute)
        and raw_assignment.value.func.attr == "strip"
        and isinstance(raw_assignment.value.func.value, ast.Call)
        and is_name(raw_assignment.value.func.value.func, "str")
        and len(raw_assignment.value.func.value.args) == 1
        and not raw_assignment.value.func.value.keywords
    ):
        return False
    raw_values = flatten_or(raw_assignment.value.func.value.args[0])
    expected_env = ast.Name(id="_WEBUI_GATEWAY_BASE_URL_ENV")
    if not (
        len(raw_values) == 3
        and is_mapping_get(raw_values[0], "source", expected_env)
        and is_mapping_get(raw_values[1], "cfg", ast.Constant(value="webui_gateway_base_url"))
        and isinstance(raw_values[2], ast.Constant)
        and raw_values[2].value == DEFAULT_GATEWAY_BASE_URL
    ):
        return False
    return (
        isinstance(returned, ast.Return)
        and isinstance(returned.value, ast.BoolOp)
        and isinstance(returned.value.op, ast.Or)
        and len(returned.value.values) == 2
        and isinstance(returned.value.values[0], ast.Call)
        and not returned.value.values[0].keywords
        and isinstance(returned.value.values[0].func, ast.Attribute)
        and returned.value.values[0].func.attr == "rstrip"
        and is_name(returned.value.values[0].func.value, "raw")
        and len(returned.value.values[0].args) == 1
        and isinstance(returned.value.values[0].args[0], ast.Constant)
        and returned.value.values[0].args[0].value == "/"
        and isinstance(returned.value.values[1], ast.Constant)
        and returned.value.values[1].value == DEFAULT_GATEWAY_BASE_URL
    )


def is_gateway_api_key_resolution(function: ast.FunctionDef | ast.AsyncFunctionDef | None) -> bool:
    """Accept only the archived env-only HERMES -> API_SERVER_KEY resolver."""
    if function is None:
        return False
    arguments = function.args
    if (
        arguments.posonlyargs
        or arguments.vararg is not None
        or arguments.kwarg is not None
        or [argument.arg for argument in arguments.args] != ["environ"]
        or len(arguments.defaults) != 1
        or not is_none(arguments.defaults[0])
        or len(function.body) != 2
    ):
        return False
    source_assignment, returned = function.body
    if not (
        isinstance(source_assignment, ast.Assign)
        and len(source_assignment.targets) == 1
        and is_name(source_assignment.targets[0], "source")
        and isinstance(source_assignment.value, ast.IfExp)
        and isinstance(source_assignment.value.test, ast.Compare)
        and len(source_assignment.value.test.ops) == 1
        and isinstance(source_assignment.value.test.ops[0], ast.Is)
        and len(source_assignment.value.test.comparators) == 1
        and is_name(source_assignment.value.test.left, "environ")
        and is_none(source_assignment.value.test.comparators[0])
        and isinstance(source_assignment.value.body, ast.Attribute)
        and source_assignment.value.body.attr == "environ"
        and is_name(source_assignment.value.body.value, "os")
        and is_name(source_assignment.value.orelse, "environ")
    ):
        return False
    if not (
        isinstance(returned, ast.Return)
        and isinstance(returned.value, ast.Call)
        and not returned.value.keywords
        and isinstance(returned.value.func, ast.Attribute)
        and returned.value.func.attr == "strip"
        and not returned.value.args
        and isinstance(returned.value.func.value, ast.Call)
        and is_name(returned.value.func.value.func, "str")
        and len(returned.value.func.value.args) == 1
        and not returned.value.func.value.keywords
    ):
        return False
    values = flatten_or(returned.value.func.value.args[0])
    expected_key_env = ast.Name(id="_WEBUI_GATEWAY_API_KEY_ENV")
    return (
        len(values) == 3
        and is_mapping_get(values[0], "source", expected_key_env)
        and is_mapping_get(values[1], "source", ast.Constant(value="API_SERVER_KEY"))
        and isinstance(values[2], ast.Constant)
        and values[2].value == ""
    )


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
    base_url_function = function_definition(module, "_gateway_base_url")
    if not is_gateway_base_url_resolution(base_url_function):
        fail("gateway base URL resolution missing trusted environment/config/default normalization contract")

    gateway_key_env = assigned_value(module, "_WEBUI_GATEWAY_API_KEY_ENV")
    if not (isinstance(gateway_key_env, ast.Constant) and gateway_key_env.value == GATEWAY_API_KEY_ENV):
        fail("gateway API key resolution missing HERMES_WEBUI_GATEWAY_API_KEY binding")
    api_key_function = function_definition(module, "_gateway_api_key")
    if not is_gateway_api_key_resolution(api_key_function):
        fail(
            "gateway API key resolution must use only the trusted "
            "HERMES_WEBUI_GATEWAY_API_KEY -> API_SERVER_KEY -> empty environment chain"
        )


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


def route_handler_passes_config_to_gateway_runner(routes: ast.Module) -> bool:
    """Require the active chat route to pass a handler config value to the runner."""
    module_aliases, runner_aliases = imported_function_aliases(
        routes, "api.gateway_chat", "_run_gateway_chat_streaming"
    )
    handler = function_definitions(routes).get("handle_post")
    if handler is None:
        return False
    handler_parameters = handler.args.args
    if (
        handler.args.posonlyargs
        or handler.args.vararg is not None
        or handler.args.kwarg is not None
        or handler.args.kwonlyargs
        or len(handler_parameters) != 1
        or handler.args.defaults
        or handler.args.kw_defaults
    ):
        return False
    handler_config_name = handler_parameters[0].arg
    for branch in (node for node in executable_nodes(handler.body) if isinstance(node, ast.If) and is_chat_start_branch(node)):
        for call in direct_calls_in(branch.body):
            if not calls_imported_function(call, module_aliases, runner_aliases, "_run_gateway_chat_streaming"):
                continue
            if (
                len(call.args) == 1
                and not call.keywords
                and is_name(call.args[0], handler_config_name)
            ):
                return True
    return False


def is_api_server_literal(node: ast.AST) -> bool:
    return isinstance(node, ast.Constant) and node.value == "api_server"


def is_selector_env_read(call: ast.Call) -> bool:
    return is_os_environ_get(call, ast.Name(id="_WEBUI_CHAT_BACKEND_ENV"))


def is_gateway_base_url_call_with_config(call: ast.Call, config_name: str) -> bool:
    return (
        call_name(call) == "_gateway_base_url"
        and len(call.args) == 1
        and not call.keywords
        and is_name(call.args[0], config_name)
    )


def is_configured_transport_call_with_config(call: ast.Call, config_name: str | None) -> bool:
    if call_name(call) is None:
        return False
    arguments = list(call.args) + [keyword.value for keyword in call.keywords]
    helper_calls = {call_name(argument) for argument in arguments if isinstance(argument, ast.Call)}
    if not {"_gateway_base_url", "_gateway_api_key"}.issubset(helper_calls):
        return False
    return config_name is None or any(
        isinstance(argument, ast.Call) and is_gateway_base_url_call_with_config(argument, config_name)
        for argument in arguments
    )


def api_server_branch_directly_calls_configured_transport(module: ast.Module) -> bool:
    functions = function_definitions(module)
    selector_names = {
        name for name, function in functions.items()
        if any(is_selector_env_read(call) for call in calls_in(function.body))
    }
    for function in functions.values():
        if (
            function.name != "_run_gateway_chat_streaming"
            or function.args.posonlyargs
            or function.args.vararg is not None
            or function.args.kwarg is not None
            or function.args.kwonlyargs
            or len(function.args.args) != 1
            or function.args.defaults
            or function.args.kw_defaults
        ):
            continue
        config_name = function.args.args[0].arg
        for branch in (node for node in executable_nodes(function.body) if isinstance(node, ast.If)):
            test_calls = calls_in(branch.test)
            if not any(is_api_server_literal(value) for value in ast.walk(branch.test)):
                continue
            if not any(call_name(call) in selector_names for call in test_calls):
                continue
            if any(
                is_configured_transport_call_with_config(call, config_name)
                for call in direct_calls_in(branch.body)
            ):
                return True
    return False


def verify_execution_reachability(server: ast.Module, routes: ast.Module, gateway: ast.Module) -> None:
    if not has_gateway_chat_import_and_activation(server):
        fail("server.py does not import and activate api.gateway_chat")
    if not server_post_handler_reaches_routes(server):
        fail("server do_POST does not reach api.routes.handle_post")
    if not route_handler_directly_calls_gateway(routes):
        fail("api.routes /api/chat/start branch does not directly call gateway selector/runner")
    if not route_handler_passes_config_to_gateway_runner(routes):
        fail("api_server transport must call _gateway_base_url with exactly one route/handler configuration argument")
    if not api_server_branch_directly_calls_configured_transport(gateway):
        fail("api_server transport must call _gateway_base_url with exactly one route/handler configuration argument")


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
