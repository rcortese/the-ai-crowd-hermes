#!/usr/bin/env python3
"""Focused source-only contract for protected Hermes 74 A2A consumption."""
from __future__ import annotations

import json
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
LOCK_PATH = ROOT / "ops/manifests/protected-hermes-a2a-base.lock.json"
VALIDATOR = ROOT / "ops/scripts/validate-protected-hermes-a2a-base-lock.py"
BUILDER = ROOT / "ops/scripts/build-persona-base-candidate.sh"

APPROVED_IMAGE = "the-ai-crowd/hermes-base:g1-74a48e796a5-amd64"
APPROVED_IMAGE_ID = "sha256:4897db2b99c5c20c8b3561a16a4667c273d5862fe9a65b733aaf38bebfe3a045"
APPROVED_SOURCE = "74a48e796a5c01c569aba90b2577123124dd2128"


class ProtectedHermesA2ABaseLockTests(unittest.TestCase):
    def test_lock_binds_the_approved_hermes_74_image_and_source(self) -> None:
        lock = json.loads(LOCK_PATH.read_text(encoding="utf-8"))
        self.assertEqual(lock["schema"], "the-ai-crowd-hermes.protected-a2a-base-lock.v2")
        self.assertEqual(lock["status"], "approved-protected-base-consumption")
        self.assertEqual(lock["protected_base"], {
            "image": APPROVED_IMAGE,
            "image_id": APPROVED_IMAGE_ID,
            "source_revision": APPROVED_SOURCE,
        })
        self.assertEqual(
            lock["persona_consumers"],
            ["moss", "jen", "denholm", "richmond", "roy", "the-elders"],
        )
        self.assertIn("five-tool", lock["a2a_transport"])
        self.assertIn("no runtime overlay", lock["a2a_transport"])

    def test_validator_accepts_only_the_approved_static_binding(self) -> None:
        valid = subprocess.run(
            [sys.executable, str(VALIDATOR), "--check-only"], text=True, capture_output=True, check=True
        )
        self.assertEqual(valid.stdout.strip(), "protected_a2a_base_lock_valid")

    def test_active_persona_builder_consumes_the_protected_lock_for_every_persona(self) -> None:
        source = BUILDER.read_text(encoding="utf-8")
        personas = ("moss", "jen", "denholm", "richmond", "roy", "the-elders")
        self.assertIn("protected-hermes-a2a-base.lock.json", source)
        self.assertNotIn("base-images.lock.json", source)
        for persona in personas:
            self.assertIn(persona, source)
            dockerfile = ROOT / "ops/images" / f"Dockerfile.{persona}"
            self.assertEqual(
                dockerfile.read_text(encoding="utf-8").splitlines()[:2],
                ["ARG HERMES_AGENT_IMAGE", "FROM ${HERMES_AGENT_IMAGE}"],
            )
        self.assertIn(".protected_base.image", source)
        self.assertIn(".protected_base.image_id", source)
        self.assertIn(".protected_base.source_revision", source)
        self.assertIn("the-ai-crowd.hermes-base-id=$EXPECTED_ID", source)
        self.assertIn("the-ai-crowd.hermes-base-source-revision=$BASE_SOURCE_REVISION", source)

    def test_legacy_runtime_overlay_delivery_is_absent_and_topology_is_unchanged(self) -> None:
        for path in (
            "ops/images/Dockerfile.runtime-a2a-moss-denholm",
            "ops/scripts/build-a2a-moss-denholm-candidate.sh",
            "ops/scripts/patch-a2a-moss-denholm-plugin.py",
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
