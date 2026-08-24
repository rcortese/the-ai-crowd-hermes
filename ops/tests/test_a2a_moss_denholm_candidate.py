#!/usr/bin/env python3
"""Static contract for the phase-1 Moss -> Denholm A2A candidate."""
from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class A2AMossDenholmCandidateTests(unittest.TestCase):
    def test_compose_has_one_internal_receiver_and_directional_credential(self) -> None:
        compose = (ROOT / "compose.yaml").read_text(encoding="utf-8")
        self.assertIn("MOSS_TO_DENHOLM_A2A_TOKEN", compose)
        self.assertIn("A2A_PEER_TOKENS: moss:${MOSS_TO_DENHOLM_A2A_TOKEN", compose)
        self.assertIn("A2A_TRUSTED_PEERS: moss", compose)
        self.assertIn("A2A_ALLOW_ALL_USERS: 'false'", compose)
        self.assertIn("    - '9900'", compose)
        self.assertNotIn("0.0.0.0:9900:9900", compose)

    def test_protected_base_supplies_the_fixed_transport_without_an_overlay(self) -> None:
        lock = (ROOT / "ops/manifests/protected-hermes-a2a-base.lock.json").read_text(encoding="utf-8")
        self.assertIn("g1-74a48e796a5-amd64", lock)
        self.assertIn("74a48e796a5c01c569aba90b2577123124dd2128", lock)
        self.assertIn("five-tool", lock)
        self.assertFalse((ROOT / "ops/images/Dockerfile.runtime-a2a-moss-denholm").exists())
        self.assertFalse((ROOT / "ops/scripts/patch-a2a-moss-denholm-plugin.py").exists())
        builder = (ROOT / "ops/scripts/build-persona-base-candidate.sh").read_text(encoding="utf-8")
        self.assertIn("protected-hermes-a2a-base.lock.json", builder)
        self.assertNotIn("base-images.lock.json", builder)
        for persona in ("moss", "jen", "denholm", "richmond", "roy", "the-elders"):
            self.assertIn(persona, builder)

    def test_config_stager_is_non_mutating_without_apply(self) -> None:
        source = (ROOT / "ops/scripts/prepare-a2a-moss-denholm-config.py").read_text(encoding="utf-8")
        self.assertIn("--apply requires --backup-dir", source)
        self.assertIn("outbound_trusted_peers", source)
        self.assertIn("MOSS_TO_DENHOLM_A2A_TOKEN", source)
        self.assertIn("a2a-platform", source)
        self.assertIn("write_atomic", source)

    def test_star_is_documented_as_future_only(self) -> None:
        doc = (ROOT / "docs/architecture/a2a-moss-denholm-phase-1.md").read_text(encoding="utf-8")
        self.assertIn("Moss ──A2A──> Denholm", doc)
        self.assertIn("Future architecture: star, not current state", doc)
        self.assertIn("This drawing is **not** an enabled topology", doc)
        self.assertIn("separate approval", doc)


if __name__ == "__main__":
    unittest.main()
