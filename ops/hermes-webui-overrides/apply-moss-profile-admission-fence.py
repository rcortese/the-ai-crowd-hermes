#!/usr/bin/env python3
"""Apply the Moss profile admission fence to one exact pinned WebUI tree."""
from __future__ import annotations

import argparse
import hashlib
from pathlib import Path

EXPECTED = {
    "server.py": "507a4e003524571010d90c2fff9c8598bc577d6466c327d02dbedcc3961a7e7d",
    "api/routes.py": "460698bbe94772abb718fb51c13b4d2d6a3f2190fa137b4443671239a902ffae",
}

MODULE = '''"""Filesystem-backed admission fence for bounded profile migrations."""
from __future__ import annotations

import json
import os
import stat
from pathlib import Path

_SCHEMA = "moss-webui-admission-fence/v1"


def fence_path() -> Path | None:
    raw = os.environ.get("HERMES_WEBUI_ADMISSION_FENCE", "").strip()
    if not raw:
        return None
    path = Path(raw)
    if not path.is_absolute():
        raise ValueError("admission fence path must be absolute")
    return path


def admission_fenced() -> bool:
    """Return False only for no configured fence or an absent fence file."""
    try:
        path = fence_path()
    except ValueError:
        return True
    if path is None:
        return False
    try:
        info = path.lstat()
    except FileNotFoundError:
        return False
    except OSError:
        return True
    if not stat.S_ISREG(info.st_mode) or info.st_uid not in {0, os.getuid()}:
        return True
    if info.st_mode & 0o022:
        return True
    try:
        record = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError, TypeError, ValueError):
        return True
    return not (
        isinstance(record, dict)
        and record.get("schema") == _SCHEMA
        and record.get("fenced") is False
    )
'''


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if text.count(old) != 1:
        raise RuntimeError(f"{label}: expected one source anchor, found {text.count(old)}")
    return text.replace(old, new)


def apply(root: Path) -> None:
    root = root.resolve(strict=True)
    for rel, expected in EXPECTED.items():
        actual = sha256(root / rel)
        if actual != expected:
            raise RuntimeError(f"{rel}: source digest mismatch: {actual}")

    server_path = root / "server.py"
    server = server_path.read_text(encoding="utf-8")
    server = replace_once(
        server,
        "from api.auth import check_auth\n",
        "from api.auth import check_auth\nfrom api.admission_fence import admission_fenced\n",
        "server import",
    )
    server = replace_once(
        server,
        """            parsed = urlparse(self.path)\n            _is_csp_report_post = (\n""",
        """            parsed = urlparse(self.path)\n            if admission_fenced():\n                return j(\n                    self,\n                    {"error": "admission_fenced", "retryable": True},\n                    status=503,\n                    extra_headers={"Retry-After": "5"},\n                )\n            _is_csp_report_post = (\n""",
        "pre-body write fence",
    )

    routes_path = root / "api/routes.py"
    routes = routes_path.read_text(encoding="utf-8")
    routes = replace_once(
        routes,
        """    payload = {\n        "status": "ok" if stream_check.get("status") == "ok" else "degraded",\n""",
        """    from api.admission_fence import admission_fenced\n\n    payload = {\n        "status": "ok" if stream_check.get("status") == "ok" else "degraded",\n        "admission_fenced": admission_fenced(),\n""",
        "health fence field",
    )

    module_path = root / "api/admission_fence.py"
    if module_path.exists():
        raise RuntimeError("api/admission_fence.py already exists")
    module_path.write_text(MODULE, encoding="utf-8")
    server_path.write_text(server, encoding="utf-8")
    routes_path.write_text(routes, encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    apply(args.root)
