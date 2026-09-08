#!/usr/bin/env python3
"""Regression contract for retirement of legacy persona RPC."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ACTIVE = [
    ROOT / "README.md",
    ROOT / "agents/public/denholm/AGENTS.md",
    ROOT / "agents/public/denholm/docs/operating-model.md",
    ROOT / "agents/public/denholm/docs/orchestration-card-pattern.md",
    ROOT / "agents/public/denholm/docs/product-owner-operating-contract.md",
    ROOT / "agents/public/denholm/skills/product-owner-completion-wrapup/SKILL.md",
    ROOT / "agents/public/jen/README.md",
    ROOT / "agents/public/jen/SOUL.md",
    ROOT / "agents/public/jen/lib/jen-envelope-emit.sh",
    ROOT / "ops/scripts/hddt-moss.sh",
    ROOT / "tests/protocol/test_no_alternative_a2a.py",
]
for path in ACTIVE:
    assert "persona" + "_rpc" not in path.read_text(encoding="utf-8"), path

assert not (ROOT / "ops/manifests/persona-rpc-tool-contract.json").exists()
assert not (ROOT / "ops/tests/test_persona_rpc_docs_contract.py").exists()
assert not (ROOT / "tests/persona-rpc-cutover.sh").exists()
compose = (ROOT / "compose.yaml").read_text(encoding="utf-8")
assert "MOSS_TO_DENHOLM_A2A_TOKEN" in compose
assert "A2A_PEER_TOKENS: moss:${MOSS_TO_DENHOLM_A2A_TOKEN" in compose
assert "A2A_TRUSTED_PEERS: moss" in compose
assert "PERSONA_CALLER_" not in compose and "PERSONA_TARGET_" not in compose
for retired in ("agents/public/jen/persona-api.example.yaml", "agents/public/denholm/persona-api.example.yaml", "agents/public/roy/persona-api.example.yaml"):
    assert not (ROOT / retired).exists(), retired
source = (ROOT / "ops/scripts/prepare-a2a-moss-denholm-config.py").read_text(encoding="utf-8")
assert "outbound_trusted_peers" in source and "denholm" in source
print("native_a2a_migration_contract_ok")
