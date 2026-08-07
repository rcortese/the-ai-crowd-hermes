#!/usr/bin/env python3
"""Restrict Hermes A2A client exposure to approved named peers.

This is an image-overlay transform, deliberately bound to the exact upstream
``tools.py`` SHA-256 passed by the Dockerfile.  It keeps Hermes A2A v1.0 wire
semantics while removing direct-URL egress, discovery, history, and fan-out
from the first Moss -> Denholm deployment.
"""
from __future__ import annotations

import argparse
import hashlib
from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if text.count(old) != 1:
        raise SystemExit(f"expected exactly one {label} preimage")
    return text.replace(old, new, 1)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tools", required=True, type=Path)
    parser.add_argument("--expected-sha256", required=True)
    args = parser.parse_args()

    original = args.tools.read_bytes()
    actual = hashlib.sha256(original).hexdigest()
    if actual != args.expected_sha256:
        raise SystemExit(f"unexpected A2A tools.py SHA-256: {actual}")
    text = original.decode("utf-8")

    old_resolver = '''def _resolve_peer(agent: str) -> Optional[dict]:
    """Resolve a peer name to {url, auth, timeout, capabilities}, or treat ``agent`` as a URL."""
    if agent.startswith("http://") or agent.startswith("https://"):
        return {"url": agent, "auth": {}, "timeout": _DEFAULT_TIMEOUT, "capabilities": []}
    cfg = _load_config()
    peers = cfg.get("a2a_agents") or {}
    entry = peers.get(agent)
    if not entry:
        return None
    return {
        "url": entry.get("url", ""),
        "auth": entry.get("auth", {}) or {},
        "timeout": int(entry.get("timeout", _DEFAULT_TIMEOUT)),
        "capabilities": entry.get("capabilities", []) or [],
        "tenant": entry.get("tenant", ""),
    }
'''
    new_resolver = '''def _resolve_peer(agent: str) -> Optional[dict]:
    """Resolve only an explicitly trusted, configured peer name.

    Direct URLs are intentionally unsupported in this deployment profile:
    configuration grants the egress edge and the tool cannot widen it.
    """
    cfg = _load_config()
    policy = cfg.get("a2a") or {}
    allowed = policy.get("outbound_trusted_peers") or []
    if not isinstance(allowed, list) or agent not in {str(item) for item in allowed}:
        return None
    peers = cfg.get("a2a_agents") or {}
    entry = peers.get(agent)
    if not isinstance(entry, dict):
        return None
    return {
        "url": entry.get("url", ""),
        "auth": entry.get("auth", {}) or {},
        "timeout": int(entry.get("timeout", _DEFAULT_TIMEOUT)),
        "capabilities": entry.get("capabilities", []) or [],
        "tenant": entry.get("tenant", ""),
    }
'''
    text = replace_once(text, old_resolver, new_resolver, "peer resolver")
    text = replace_once(
        text,
        '"Configured peer name (from a2a_agents) or a full http(s):// URL."',
        '"Approved configured peer name. Direct URLs are not accepted."',
        "a2a_call schema",
    )
    text = replace_once(
        text,
        '    ``agent`` is a configured peer name (from ``a2a_agents``) or a direct URL.\n',
        '    ``agent`` must be an approved configured peer name.\n',
        "a2a_call documentation",
    )
    text = replace_once(
        text,
        "            f\"Error: unknown agent '{agent}'. Configure it under 'a2a_agents' in \"\n            f\"config.yaml or pass a full http(s):// URL.\"\n",
        "            f\"Error: peer '{agent}' is not an approved configured A2A peer.\"\n",
        "a2a_call error",
    )
    old_register = '''def register_tools(ctx) -> None:
    """Register the client tools in the ``a2a`` toolset."""
    for name, schema in _SCHEMAS.items():
        ctx.register_tool(
            name=name,
            toolset="a2a",
            schema=schema,
            handler=_HANDLERS[name],
            description=schema["function"]["description"],
            emoji="\\U0001f9e9",  # puzzle piece
        )
'''
    new_register = '''def register_tools(ctx) -> None:
    """Register only the bounded peer-call tool for this deployment profile."""
    name = "a2a_call"
    schema = _SCHEMAS[name]
    ctx.register_tool(
        name=name,
        toolset="a2a",
        schema=schema,
        handler=_HANDLERS[name],
        description=schema["function"]["description"],
        emoji="\\U0001f9e9",  # puzzle piece
    )
'''
    text = replace_once(text, old_register, new_register, "tool registration")
    args.tools.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    main()
