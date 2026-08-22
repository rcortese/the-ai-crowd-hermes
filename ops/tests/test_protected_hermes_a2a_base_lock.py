#!/usr/bin/env python3
"""Focused source-only contract for future protected Hermes A2A consumption."""
from __future__ import annotations

import json
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
VALIDATOR = ROOT / "ops/scripts/validate-protected-hermes-a2a-base-lock.py"


class ProtectedHermesA2ABaseLockTests(unittest.TestCase):
    def test_pending_lock_names_inputs_without_inventing_a_base(self) -> None:
        lock = json.loads((ROOT / "ops/manifests/protected-hermes-a2a-base.lock.json").read_text())
        self.assertEqual(lock["status"], "pending-external-protected-base-binding")
        self.assertEqual(lock["required_input"]["image_id"], "HERMES_PROTECTED_A2A_BASE_ID")
        self.assertEqual(lock["required_input"]["source_revision"], "HERMES_PROTECTED_A2A_SOURCE_REVISION")
        self.assertEqual(lock["expected_source_candidate"], "2599c9e3e931e2707dc39025b6203eb1c1e08687")
        self.assertEqual(lock["protected_base"], {"image_id": None, "source_revision": None})

    def test_validator_accepts_only_a_matched_future_immutable_input(self) -> None:
        pending = subprocess.run([sys.executable, str(VALIDATOR)], text=True, capture_output=True, check=True)
        self.assertEqual(pending.stdout.strip(), "protected_a2a_base_lock_pending")
        valid = subprocess.run([
            sys.executable, str(VALIDATOR), "--base-id", "sha256:" + "a" * 64,
            "--source-revision", "2599c9e3e931e2707dc39025b6203eb1c1e08687",
        ], text=True, capture_output=True, check=True)
        self.assertEqual(valid.stdout.strip(), "protected_a2a_base_input_valid")
        rejected = subprocess.run([
            sys.executable, str(VALIDATOR), "--base-id", "sha256:" + "a" * 64,
            "--source-revision", "0" * 40,
        ], text=True, capture_output=True)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("does not match expected candidate", rejected.stderr)

    def test_legacy_runtime_copy_delivery_is_absent(self) -> None:
        for path in (
            "ops/images/Dockerfile.moss-a2a-overlay",
            "ops/images/Dockerfile.runtime-a2a-overlay",
            "ops/scripts/build-moss-a2a-overlay-candidate.sh",
            "ops/scripts/build-runtime-a2a-overlay-candidate.sh",
            "ops/scripts/materialize-persona-toolset-runtime.py",
        ):
            self.assertFalse((ROOT / path).exists(), path)

        compose = (ROOT / "compose.yaml").read_text(encoding="utf-8")
        self.assertIn("    - '9900'", compose)
        self.assertNotIn("0.0.0.0:9900:9900", compose)
        self.assertIn("A2A_TRUSTED_PEERS: moss", compose)


if __name__ == "__main__":
    unittest.main()