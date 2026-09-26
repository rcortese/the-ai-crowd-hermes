#!/usr/bin/env python3
"""Apply the inline-delegation HTTP overlay to one exact Moss image preimage.

No network, session data, or credentials are read. Default root is /opt.
"""
import hashlib
import os
import sys
from pathlib import Path

ROOT = Path(sys.argv[1] if len(sys.argv) == 2 else "/opt")
# The preimages are bound to the running image, not to the newer source forks.
FILES = {
    "hermes/gateway/platforms/api_server_openai_routes.py": (
        "1defb80f39650a60306c815f29ae6710e804eba0ef307aea86ebff7f69f872db",
        'session_history_delivery=("1" if provided_session_id else ""))',
        'session_history_delivery=("1" if provided_session_id and\n'
        '                                      request.headers.get("X-Hermes-Delegate-Mode", "").strip().lower() != "inline"\n'
        '                                      else ""))',
    ),
    "hermes/gateway/platforms/api_server_runs.py": (
        "63c3353ad1108a3ce95adca07155b9d1369d7fa7fea2cb6b8032cd60ac00f2d1",
        'session_history_delivery = not previous_response_id and not conversation_history',
        'session_history_delivery = (not previous_response_id and not conversation_history and\n'
        '                                request.headers.get("X-Hermes-Delegate-Mode", "").strip().lower() != "inline")',
    ),
    "hermes-webui/api/gateway_chat.py": (
        "4af741bd946f139f20d543959ec73ea14b8b114e22db1faf749ab5ac37deda65",
        '"X-Hermes-Session-Id": session_id,\n',
        '"X-Hermes-Session-Id": session_id,\n'
        '        "X-Hermes-Delegate-Mode": "inline",\n',
    ),
}


def digest(value):
    return hashlib.sha256(value).hexdigest()


def transform(root):
    # Validate every input before the first mutation. Build container is disposable;
    # the preimage guard prevents accidental patching of an unrelated image.
    changes = []
    for name, (expected, old, new) in FILES.items():
        path = root / name
        source = path.read_bytes()
        if digest(source) != expected:
            raise RuntimeError(f"preimage mismatch: {name}")
        text = source.decode("utf-8")
        matches = 2 if name == "hermes-webui/api/gateway_chat.py" else 1
        if text.count(old) != matches:
            raise RuntimeError(f"anchor mismatch: {name}")
        result = text.replace(old, new).encode("utf-8")
        compile(result, str(path), "exec")
        changes.append((path, result, name))
    for path, result, name in changes:
        mode = path.stat().st_mode
        path.write_bytes(result)
        os.chmod(path, mode)
        print(f"{name} {digest(result)}")


if __name__ == "__main__":
    transform(ROOT)
