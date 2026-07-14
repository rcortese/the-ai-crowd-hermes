#!/usr/bin/env python3
"""Runtime contract for every Hermes persona image's write-safety guard.

Run inside an image: /opt/hermes/.venv/bin/python3 write-safe-root-contract.py.
This is intentionally dependency-free so Dockerfiles can execute it at build time.
"""
from __future__ import annotations

import inspect
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from agent import file_safety
from agent import copilot_acp_client
from tools.file_operations import ShellFileOperations


class LocalTerminal:
    """Minimal real shell backend for exercising ShellFileOperations."""

    def __init__(self, cwd: str) -> None:
        self.cwd = cwd

    def execute(self, command: str, cwd: str | None = None, timeout: int | None = None,
                stdin_data: str | None = None) -> dict[str, object]:
        result = subprocess.run(
            command,
            shell=True,
            cwd=cwd or self.cwd,
            input=stdin_data,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
            check=False,
        )
        return {"output": result.stdout, "returncode": result.returncode}


class WriteSafeRootContract(unittest.TestCase):
    """Behavioral compatibility contract; production code must not import this."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="write-safe-root-contract-")
        self.root = Path(self.tmp.name).resolve()
        self.allowed = tuple((self.root / f"allowed-{i}") for i in range(1, 4))
        self.outside = self.root / "outside"
        self.home_root = self.root / "hermes"
        self.active_home = self.home_root / "profiles" / "moss"
        for path in (*self.allowed, self.outside, self.active_home, self.home_root):
            path.mkdir(parents=True, exist_ok=True)
        self.old_env = os.environ.get("HERMES_WRITE_SAFE_ROOT")
        self.old_home = file_safety._hermes_home_path
        self.old_root = file_safety._hermes_root_path
        file_safety._hermes_home_path = lambda: self.active_home
        file_safety._hermes_root_path = lambda: self.home_root

    def tearDown(self) -> None:
        if self.old_env is None:
            os.environ.pop("HERMES_WRITE_SAFE_ROOT", None)
        else:
            os.environ["HERMES_WRITE_SAFE_ROOT"] = self.old_env
        file_safety._hermes_home_path = self.old_home
        file_safety._hermes_root_path = self.old_root
        self.tmp.cleanup()

    def configure(self, value: str) -> None:
        os.environ["HERMES_WRITE_SAFE_ROOT"] = value

    def denied_error(self, path: Path, verb: str = "write") -> str | None:
        # The required public API makes denial diagnostics consistent for every caller.
        return file_safety.get_write_denied_error(str(path), verb=verb)

    def test_multiple_roots_allow_each_component_and_deny_outside_boundary_sibling(self) -> None:
        self.configure(os.pathsep.join(map(str, self.allowed)))
        self.assertEqual(file_safety.get_safe_write_roots(), {str(p) for p in self.allowed})
        for index, root in enumerate(self.allowed, 1):
            self.assertFalse(file_safety.is_write_denied(str(root / "probe.txt")), f"root {index}")
        self.assertTrue(file_safety.is_write_denied(str(self.outside / "probe.txt")))
        self.assertTrue(file_safety.is_write_denied(str(Path(str(self.allowed[0]) + "-sibling") / "probe.txt")))
        self.assertIn("outside HERMES_WRITE_SAFE_ROOT", self.denied_error(self.outside / "probe.txt") or "")

    def test_empty_components_duplicates_tilde_and_symlink_do_not_expand_allowlist(self) -> None:
        alias = self.root / "alias"
        alias.symlink_to(self.allowed[0], target_is_directory=True)
        self.configure(os.pathsep.join(("", str(self.allowed[0]), "", str(alias), str(self.allowed[0]), "")))
        self.assertEqual(file_safety.get_safe_write_roots(), {str(self.allowed[0])})
        self.assertFalse(file_safety.is_write_denied(str(alias / "inside.txt")))
        self.assertTrue(file_safety.is_write_denied(str(self.outside / "outside.txt")))


    def test_actual_tilde_root_expands_against_home(self) -> None:
        # Use a real '~' entry rather than only a pre-expanded fixture path.
        with mock.patch.dict(os.environ, {"HOME": str(self.root)}):
            self.configure("~/allowed-1")
            self.assertEqual(file_safety.get_safe_write_roots(), {str(self.allowed[0])})
            self.assertFalse(file_safety.is_write_denied(str(self.allowed[0] / "inside.txt")))

    def test_symlink_below_allowed_root_cannot_escape_to_outside(self) -> None:
        self.configure(str(self.allowed[0]))
        escape = self.allowed[0] / "escape"
        escape.symlink_to(self.outside, target_is_directory=True)
        self.assertTrue(file_safety.is_write_denied(str(escape / "blocked.txt")))

    def test_all_invalid_oserror_and_valueerror_configs_fail_closed(self) -> None:
        invalid_oserror = self.root / "invalid-oserror"
        invalid_valueerror = self.root / "invalid-valueerror"
        original_realpath = file_safety.os.path.realpath

        def realpath(path: object) -> str:
            if str(path) == str(invalid_oserror):
                raise OSError("synthetic invalid root")
            if str(path) == str(invalid_valueerror):
                raise ValueError("synthetic invalid root")
            return original_realpath(path)

        self.configure(os.pathsep.join((str(invalid_oserror), str(invalid_valueerror))))
        with mock.patch.object(file_safety.os.path, "realpath", side_effect=realpath):
            self.assertEqual(file_safety.get_safe_write_roots(), set())
            self.assertEqual(
                self.denied_error(self.allowed[0] / "must-not-open.txt"),
                "HERMES_WRITE_SAFE_ROOT has no valid roots",
            )

    def test_mixed_invalid_and_valid_roots_keep_only_valid_allowlist(self) -> None:
        invalid_oserror = self.root / "invalid-oserror"
        invalid_valueerror = self.root / "invalid-valueerror"
        original_realpath = file_safety.os.path.realpath

        def realpath(path: object) -> str:
            if str(path) == str(invalid_oserror):
                raise OSError("synthetic invalid root")
            if str(path) == str(invalid_valueerror):
                raise ValueError("synthetic invalid root")
            return original_realpath(path)

        self.configure(os.pathsep.join((str(invalid_oserror), str(self.allowed[0]), str(invalid_valueerror))))
        with mock.patch.object(file_safety.os.path, "realpath", side_effect=realpath):
            self.assertEqual(file_safety.get_safe_write_roots(), {str(self.allowed[0])})
            self.assertFalse(file_safety.is_write_denied(str(self.allowed[0] / "allowed.txt")))
            self.assertTrue(file_safety.is_write_denied(str(self.allowed[1] / "blocked.txt")))

    def test_full_exact_and_prefix_hard_deny_matrix_wins_over_home_allowlist(self) -> None:
        # $HOME is intentionally allowlisted: every exact and prefix deny must still win.
        with mock.patch.dict(os.environ, {"HOME": str(self.root)}):
            self.configure(os.pathsep.join((str(self.root), str(self.home_root))))
            exact = (
                self.root / ".ssh" / "authorized_keys", self.root / ".ssh" / "id_rsa",
                self.root / ".ssh" / "id_ed25519", self.root / ".ssh" / "config",
                self.root / ".netrc", self.root / ".pgpass", self.root / ".npmrc",
                self.root / ".pypirc", self.root / ".git-credentials", self.active_home / ".env",
                self.home_root / ".env", self.active_home / ".anthropic_oauth.json",
                self.home_root / ".anthropic_oauth.json", Path("/etc/sudoers"),
                Path("/etc/passwd"), Path("/etc/shadow"),
            )
            prefixes = (
                self.root / ".ssh" / "nested", self.root / ".aws" / "credentials",
                self.root / ".gnupg" / "private-keys-v1.d" / "key", self.root / ".kube" / "config",
                self.root / ".docker" / "config.json", self.root / ".azure" / "accessTokens.json",
                self.root / ".config" / "gh" / "hosts.yml", self.root / ".config" / "gcloud" / "credentials.db",
                Path("/etc/sudoers.d/test"), Path("/etc/systemd/system/test.service"),
            )
            for target in (*exact, *prefixes):
                self.assertTrue(file_safety.is_write_denied(str(target)), target)
                self.assertIn("protected system/credential file", self.denied_error(target) or "")

    def test_mounted_read_only_profile_inventory_keeps_all_credential_stores_denied(self) -> None:
        # Candidate/runtime callers mount this inventory read-only; this test only reads it.
        inventory_root = Path(os.environ.get("HERMES_PROFILE_INVENTORY_ROOT", "/opt/data"))
        self.assertTrue(inventory_root.is_dir(), inventory_root)
        profile_homes = [("default", inventory_root)]
        profiles_dir = inventory_root / "profiles"
        if profiles_dir.is_dir():
            profile_homes.extend((path.name, path) for path in sorted(profiles_dir.iterdir()) if path.is_dir())
        original_home = file_safety._hermes_home_path
        original_root = file_safety._hermes_root_path
        self.configure(str(self.root))
        try:
            file_safety._hermes_root_path = lambda: inventory_root
            for profile, home in profile_homes:
                file_safety._hermes_home_path = lambda home=home: home
                for store in ("mcp-tokens", "pairing"):
                    self.assertTrue(file_safety.is_write_denied(str(home / store / "probe")), f"{profile}:{store}")
        finally:
            file_safety._hermes_home_path = original_home
            file_safety._hermes_root_path = original_root

    def test_nonempty_config_without_valid_roots_fails_closed(self) -> None:
        self.configure(os.pathsep * 2)
        self.assertTrue(file_safety.is_write_denied(str(self.allowed[0] / "must-not-open.txt")))
        self.assertEqual(
            self.denied_error(self.allowed[0] / "must-not-open.txt"),
            "HERMES_WRITE_SAFE_ROOT has no valid roots",
        )

    def test_hard_denies_and_profile_credential_stores_win_over_allowlist(self) -> None:
        # Include the runtime home in the allowlist so this proves hard-deny precedence.
        self.configure(os.pathsep.join((str(self.root), str(Path.home()))))
        protected = (
            Path.home() / ".ssh" / "id_ed25519",
            self.active_home / "mcp-tokens" / "token.json",
            self.active_home / "pairing" / "pair.json",
            self.home_root / "mcp-tokens" / "token.json",
            self.home_root / "pairing" / "pair.json",
        )
        for target in protected:
            self.assertTrue(file_safety.is_write_denied(str(target)), target)
            self.assertIn("protected system/credential file", self.denied_error(target) or "")

    def test_named_and_default_profile_homes_keep_credential_stores_denied(self) -> None:
        self.configure(str(self.root))
        for profile in ("default", "moss", "named-profile"):
            active = self.home_root if profile == "default" else self.home_root / "profiles" / profile
            active.mkdir(parents=True, exist_ok=True)
            original = file_safety._hermes_home_path
            file_safety._hermes_home_path = lambda active=active: active
            try:
                self.assertTrue(file_safety.is_write_denied(str(active / "mcp-tokens" / "x")), profile)
                self.assertTrue(file_safety.is_write_denied(str(active / "pairing" / "x")), profile)
            finally:
                file_safety._hermes_home_path = original

    def test_cross_profile_soft_guard_still_warns(self) -> None:
        self.configure(str(self.root))
        target = self.home_root / "profiles" / "other" / "skills" / "SKILL.md"
        warning = file_safety.get_cross_profile_warning(str(target))
        self.assertIsNotNone(warning)
        self.assertIn("Cross-profile write blocked", warning or "")

    def test_file_operations_share_outside_allowlist_diagnostics(self) -> None:
        self.configure(str(self.allowed[0]))
        operations = ShellFileOperations(LocalTerminal(str(self.root)))
        permitted = self.allowed[0] / "permitted.txt"
        self.assertIsNone(operations.write_file(str(permitted), "before\n").error)
        self.assertIsNone(operations.patch_replace(str(permitted), "before", "after").error)
        self.assertTrue(permitted.exists())
        self.assertIsNone(operations.move_file(str(permitted), str(self.allowed[0] / "moved.txt")).error)
        self.assertIsNone(operations.delete_file(str(self.allowed[0] / "moved.txt")).error)

        outside = self.outside / "blocked.txt"
        self.assertIn("outside HERMES_WRITE_SAFE_ROOT", operations.write_file(str(outside), "no\n").error or "")
        self.assertIn("outside HERMES_WRITE_SAFE_ROOT", operations.patch_replace(str(outside), "x", "y").error or "")
        self.assertIn("outside HERMES_WRITE_SAFE_ROOT", operations.delete_file(str(outside)).error or "")
        self.assertIn("outside HERMES_WRITE_SAFE_ROOT", operations.move_file(str(outside), str(self.allowed[0] / "dst.txt")).error or "")
        self.assertIn("outside HERMES_WRITE_SAFE_ROOT", operations.move_file(str(self.allowed[0] / "src.txt"), str(outside)).error or "")
        self.assertFalse(outside.exists())

    def test_acp_shim_uses_shared_diagnostic_api(self) -> None:
        source = inspect.getsource(copilot_acp_client)
        self.assertIn("get_write_denied_error", source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
