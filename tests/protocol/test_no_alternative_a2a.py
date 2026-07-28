#!/usr/bin/env python3
"""Fail closed if a retired interpersona transport returns to active source.

This audits executable/runtime surfaces, not historical evidence or ordinary
human-language uses of "handoff" in session/product documentation.
"""
from __future__ import annotations

import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

RETIRED_PATHS = {
    "agents/public/jen/tools/cron-scripts/jen-new-day-precompute.sh",
    "agents/public/denholm/skills/agent-handoff-spec/SKILL.md",
    "shared/protocol/bin/the-ai-crowd-handoff",
    "shared/protocol/lib/persona_handoff_wrapper.py",
    "shared/protocol/lib/the_ai_crowd_handoff.py",
}

# These strings denote executable transports/fallbacks, not generic prose.
FORBIDDEN_RUNTIME_TOKENS = (
    "/mnt/hermes-shared/handoffs",
    "/mnt/hermes-shared/handoffs_processed",
    "/mnt/hermes-shared/handoffs_quarantine",
    "/mnt/hermes-shared/protocol",
    "/mnt/hermes-shared/roy-handoff",
    "state/shared/handoffs",
    "state/shared/handoffs_processed",
    "state/shared/handoffs_quarantine",
    "state/shared/protocol",
    "state/shared/roy-handoff",
    "persona_handoff_wrapper",
    "the-ai-crowd-handoff",
    "jen_to_moss_handoff_watch",
    "jen-new-day-precompute.sh",
    "jen precompute new-day handoff",
    "moss jen handoff watcher",
    "wakeup-handoff.json",
    "jen-new-day-handoff.v1",
    "a2a-lite",
    "persona_dispatch",
    "HERMES_KANBAN_HOME=/mnt/hermes-shared",
    "HERMES_KANBAN_DISPATCH_UNOWNED_BOARDS=true",
)

RUNTIME_SUFFIXES = {".py", ".sh", ".bash", ".yaml", ".yml", ".toml", ".json"}
RUNTIME_PREFIXES = (
    "agents/public/",
    "ops/images/",
    "ops/scripts/",
    "ops/supervisor/",
    "profiles/",
    "scripts/",
    "bin/",
    "docker/",
    "shared/",
    "compose",
)
PASSIVE_PREFIXES = ("docs/", "examples/", "honcho-local/", ".github/")


def tracked_entries() -> dict[str, str]:
    result = subprocess.run(
        ["git", "-c", f"safe.directory={ROOT}", "ls-files", "--stage"],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=True,
    )
    entries: dict[str, str] = {}
    for line in result.stdout.splitlines():
        metadata, path = line.split("\t", 1)
        mode = metadata.split(" ", 1)[0]
        entries[path] = mode
    return entries


def is_runtime_surface(path: str, mode: str) -> bool:
    if path.startswith(PASSIVE_PREFIXES) or path.startswith("tests/"):
        return False
    if "/tests/" in path or "/docs/" in path or path.startswith("ops/tests/"):
        return False
    # Any executable tracked anywhere outside passive/test trees is active until
    # explicitly classified otherwise. This closes extensionless/root-level gaps.
    if mode == "100755":
        return True
    if not path.startswith(RUNTIME_PREFIXES):
        return False
    p = Path(path)
    return p.suffix in RUNTIME_SUFFIXES or p.name.startswith("Dockerfile") or "/bin/" in path


def retired_token_hits(path: str, mode: str, text: str) -> list[str]:
    if not is_runtime_surface(path, mode):
        return []
    folded = text.casefold()
    return [f"{path}: {token}" for token in FORBIDDEN_RUNTIME_TOKENS if token.casefold() in folded]


class NoAlternativeA2ATests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.entries = tracked_entries()
        cls.tracked = list(cls.entries)

    def test_retired_implementations_are_untracked(self) -> None:
        present = sorted(RETIRED_PATHS.intersection(self.tracked))
        self.assertEqual([], present)
        legacy_bins = [
            path for path in self.tracked
            if path.startswith("agents/public/") and "/bin/" in path
            and Path(path).name.endswith("-handoff")
        ]
        self.assertEqual([], legacy_bins)
        self.assertFalse(any(path.startswith("shared/protocol/") for path in self.tracked))

    def test_no_retired_transport_token_in_runtime_surfaces(self) -> None:
        hits: list[str] = []
        for relative, mode in self.entries.items():
            path = ROOT / relative
            try:
                text = path.read_text(encoding="utf-8")
            except (UnicodeDecodeError, OSError):
                continue
            hits.extend(retired_token_hits(relative, mode, text))
        self.assertEqual([], hits)

    def test_compose_has_only_persona_rpc_interpersona_channel(self) -> None:
        compose = (ROOT / "compose.yaml").read_text(encoding="utf-8")
        folded = compose.casefold()
        self.assertIn("api_server_enabled", folded)
        self.assertIn("persona_caller_moss_token", folded)
        self.assertIn("persona_target_moss_token", folded)
        for token in ("nats", "jetstream", "a2a-lite", "persona_dispatch"):
            self.assertNotIn(token, folded)

    def test_jen_has_no_handoff_named_cron_script(self) -> None:
        cron_root = ROOT / "agents/public/jen/tools/cron-scripts"
        names = sorted(p.name for p in cron_root.glob("*") if "handoff" in p.name.casefold())
        self.assertEqual([], names)

    def test_no_active_skill_routes_retired_handoff_spec(self) -> None:
        hits: list[str] = []
        for relative in self.tracked:
            if not relative.startswith("agents/public/") or not relative.endswith(".md"):
                continue
            text = (ROOT / relative).read_text(encoding="utf-8")
            if "agent-handoff-spec" in text:
                hits.append(relative)
        self.assertEqual([], hits)

    def test_negative_roy_handoff_producer_is_detected(self) -> None:
        hits = retired_token_hits(
            "agents/public/jen/tools/recovery/recreate.sh",
            "100755",
            "mkdir -p /mnt/hermes-shared/roy-handoff\n",
        )
        self.assertEqual(
            ["agents/public/jen/tools/recovery/recreate.sh: /mnt/hermes-shared/roy-handoff"],
            hits,
        )

    def test_negative_root_extensionless_executable_is_detected(self) -> None:
        synthetic = "scripts/recreate"
        self.assertTrue(is_runtime_surface(synthetic, "100755"))
        hits = retired_token_hits(
            synthetic,
            "100755",
            "exec /mnt/hermes-shared/protocol/bin/the-ai-crowd-handoff\n",
        )
        self.assertIn(f"{synthetic}: /mnt/hermes-shared/protocol", hits)
        self.assertIn(f"{synthetic}: the-ai-crowd-handoff", hits)


if __name__ == "__main__":
    unittest.main()
