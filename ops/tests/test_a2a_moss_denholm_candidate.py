#!/usr/bin/env python3
"""Static contract for the phase-1 Moss -> Denholm A2A candidate."""
from __future__ import annotations

import py_compile
import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PREPARER_PATH = ROOT / "ops/scripts/prepare-a2a-moss-denholm-config.py"
SPEC = importlib.util.spec_from_file_location("prepare_a2a_moss_denholm_config", PREPARER_PATH)
assert SPEC and SPEC.loader
PREPARER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PREPARER)


class A2AMossDenholmCandidateTests(unittest.TestCase):
    def test_compose_has_one_internal_receiver_and_directional_credential(self) -> None:
        compose = (ROOT / "compose.yaml").read_text(encoding="utf-8")
        self.assertIn("MOSS_TO_DENHOLM_A2A_TOKEN", compose)
        self.assertIn("A2A_PEER_TOKENS: moss:${MOSS_TO_DENHOLM_A2A_TOKEN", compose)
        self.assertIn("A2A_TRUSTED_PEERS: moss", compose)
        self.assertIn("A2A_ALLOW_ALL_USERS: 'false'", compose)
        self.assertIn("    - '9900'", compose)
        self.assertNotIn("0.0.0.0:9900:9900", compose)
        self.assertNotIn("MOSS_TO_DENHOLM_PERSONA_TOKEN", compose)
        self.assertNotIn("PERSONA_TARGET_DENHOLM_TOKEN", compose)
        self.assertIn("DENHOLM_TO_MOSS_PERSONA_TOKEN", compose)
        self.assertNotIn("HERMES_WEBUI_PROFILE_PROXY_DENHOLM", compose)

    def test_overlay_is_preimage_bound_and_restricts_exposure(self) -> None:
        dockerfile = (ROOT / "ops/images/Dockerfile.runtime-a2a-moss-denholm").read_text(encoding="utf-8")
        patcher = ROOT / "ops/scripts/patch-a2a-moss-denholm-plugin.py"
        source = patcher.read_text(encoding="utf-8")
        self.assertIn("--expected-sha256", dockerfile)
        self.assertIn("outbound_trusted_peers", source)
        self.assertIn("Direct URLs are intentionally unsupported", source)
        self.assertIn('name = "a2a_call"', source)
        self.assertIn("Register only the bounded peer-call tool", source)
        self.assertIn("Direct URLs are intentionally unsupported", source)
        py_compile.compile(str(patcher), doraise=True)

    def test_config_stager_is_non_mutating_without_apply(self) -> None:
        source = (ROOT / "ops/scripts/prepare-a2a-moss-denholm-config.py").read_text(encoding="utf-8")
        self.assertIn("--apply requires --backup-dir", source)
        self.assertIn("outbound_trusted_peers", source)
        self.assertIn("MOSS_TO_DENHOLM_A2A_TOKEN", source)
        self.assertIn("a2a-platform", source)
        self.assertIn("write_atomic", source)

    def test_config_stager_retires_predecessor_even_when_a2a_is_already_present(self) -> None:
        moss = """persona_api:
  outbound:
    targets:
      denholm:
        url: http://denholm:8643
# THE-AI-CROWD A2A MOSS-DENHOLM PHASE-1
a2a:
  outbound_trusted_peers:
  - denholm
"""
        denholm = """persona_api:
  self_target: denholm
  inbound:
    callers:
      moss:
        allow_targets:
          - denholm
  outbound:
    targets:
      moss:
        url: http://moss:8648
# THE-AI-CROWD A2A MOSS-DENHOLM PHASE-1
"""
        staged_moss = PREPARER.moss_candidate(moss)
        staged_denholm = PREPARER.denholm_candidate(denholm)
        self.assertNotIn("http://denholm:8643", staged_moss)
        self.assertNotIn("allow_targets", staged_denholm)
        self.assertIn("url: http://moss:8648", staged_denholm)

    def test_star_is_documented_as_future_only(self) -> None:
        doc = (ROOT / "docs/architecture/a2a-moss-denholm-phase-1.md").read_text(encoding="utf-8")
        self.assertIn("Moss ──A2A──> Denholm", doc)
        self.assertIn("Future architecture: star, not current state", doc)
        self.assertIn("This drawing is **not** an enabled topology", doc)
        self.assertIn("separate approval", doc)


if __name__ == "__main__":
    unittest.main()
