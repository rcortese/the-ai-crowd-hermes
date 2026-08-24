#!/usr/bin/env python3
"""Fail-closed archive contract for Roy's WebUI api_server backend."""
from __future__ import annotations

import argparse
import sys
import tarfile
from typing import NoReturn

REQUIRED = ("server.py", "api/gateway_chat.py")
REQUIRED_GATEWAY_LITERALS = (
    "HERMES_WEBUI_CHAT_BACKEND",
    "api_server",
    "HERMES_WEBUI_GATEWAY_BASE_URL",
    "HERMES_WEBUI_GATEWAY_API_KEY",
    "API_SERVER_KEY",
)


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


def compile_source(name: str, source: str) -> None:
    try:
        compile(source, name, "exec", dont_inherit=True)
    except SyntaxError as exc:
        fail(f"compile failed for {name}: {exc.msg} at line {exc.lineno}")


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

    for name, contents in source.items():
        compile_source(name, contents)
    gateway = source["api/gateway_chat.py"]
    for literal in REQUIRED_GATEWAY_LITERALS:
        if literal not in gateway:
            fail(f"api_server backend contract missing {literal!r} in api/gateway_chat.py")
    print("roy-webui-api-server-archive-contract: PASS required=server.py,api/gateway_chat.py")


if __name__ == "__main__":
    main()
