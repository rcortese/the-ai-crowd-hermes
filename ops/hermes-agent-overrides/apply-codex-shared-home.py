#!/usr/bin/env python3
"""Patch Hermes auth.py to support a dedicated shared auth-store root.

The upstream Hermes release pins auth.json to HERMES_HOME. The AI Crowd needs a
separate auth-store path so several personas can share one OpenAI Codex OAuth
session without also sharing sessions/config/memory under the same home.

This patch is intentionally strict and build-time verified:
- if the expected upstream function body changes, the build fails instead of
  silently producing a partial patch;
- if the patch is already present, the script exits cleanly.
"""

from pathlib import Path
import py_compile

TARGET = Path("/opt/hermes/hermes_cli/auth.py")

OLD = """def _auth_file_path() -> Path:
    path = get_hermes_home() / "auth.json"
    # Seat belt: if pytest is running and HERMES_HOME resolves to the real
    # user's auth store, refuse rather than silently corrupt it. This catches
    # tests that forgot to monkeypatch HERMES_HOME, tests invoked without the
    # hermetic conftest, or sandbox escapes via threads/subprocesses. In
    # production (no PYTEST_CURRENT_TEST) this is a single dict lookup.
    if os.environ.get("PYTEST_CURRENT_TEST"):
        real_home_auth = (Path.home() / ".hermes" / "auth.json").resolve(strict=False)
        try:
            resolved = path.resolve(strict=False)
        except Exception:
            resolved = path
        if resolved == real_home_auth:
            raise RuntimeError(
                f"Refusing to touch real user auth store during test run: {path}. "
                "Set HERMES_HOME to a tmp_path in your test fixture, or run "
                "via scripts/run_tests.sh for hermetic CI-parity env."
            )
    return path
"""

NEW = """def _auth_file_path() -> Path:
    auth_home_override = os.getenv("HERMES_AUTH_HOME", "").strip()
    auth_root = Path(auth_home_override).expanduser() if auth_home_override else get_hermes_home()
    path = auth_root / "auth.json"
    # Seat belt: if pytest is running and the resolved auth store points at the real
    # user's auth file, refuse rather than silently corrupt it. This catches
    # tests that forgot to monkeypatch HERMES_HOME/HERMES_AUTH_HOME, tests invoked without the
    # hermetic conftest, or sandbox escapes via threads/subprocesses. In
    # production (no PYTEST_CURRENT_TEST) this is a single dict lookup.
    if os.environ.get("PYTEST_CURRENT_TEST"):
        real_home_auth = (Path.home() / ".hermes" / "auth.json").resolve(strict=False)
        try:
            resolved = path.resolve(strict=False)
        except Exception:
            resolved = path
        if resolved == real_home_auth:
            raise RuntimeError(
                f"Refusing to touch real user auth store during test run: {path}. "
                "Set HERMES_HOME or HERMES_AUTH_HOME to a tmp_path in your test fixture, or run "
                "via scripts/run_tests.sh for hermetic CI-parity env."
            )
    return path
"""


def main() -> None:
    text = TARGET.read_text()
    if NEW in text:
        py_compile.compile(str(TARGET), doraise=True)
        print("codex-shared-home: already patched")
        return
    if OLD not in text:
        raise SystemExit(
            "codex-shared-home: expected upstream _auth_file_path block not found; "
            "refusing to patch unknown auth.py layout"
        )
    TARGET.write_text(text.replace(OLD, NEW, 1))
    py_compile.compile(str(TARGET), doraise=True)
    print("codex-shared-home: patched /opt/hermes/hermes_cli/auth.py")


if __name__ == "__main__":
    main()
