#!/usr/bin/env python3
"""Fail-closed validation for the unbuilt Hermes base v4 contract."""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any, Mapping

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_LOCK = ROOT / "ops/manifests/hermes-base-v4.lock.json"
SHA256 = re.compile(r"sha256:[0-9a-f]{64}\Z")
OID = re.compile(r"[0-9a-f]{40}\Z")
EXPECTED = {
    "schema": "the-ai-crowd.hermes-base-contract.v4",
    "status": "source-only-unbuilt",
    "source": {
        "tag": "v2026.8.19",
        "commit": "fcbd1076a93841fa88855acce810e342a5b78101",
        "tree": "cc9f987a403a1d02b8b17cc527a57b54402e864b",
    },
    "requested_platform": "linux/amd64",
    "oci_index_digest": "sha256:3811ed13da874fba2ac99b6d492db9a203d34cb6dccf90d886948c00d0ccec09",
}
UNRESOLVED_FIELDS = ("platform_manifest_digest", "config_digest", "local_image_id")


class ContractError(ValueError):
    """The source-only contract is not safe to consume."""


def load_contract(path: Path = DEFAULT_LOCK) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ContractError(f"hermes_base_v4_invalid_lock: {exc}") from exc
    if not isinstance(value, dict):
        raise ContractError("hermes_base_v4_invalid_lock: top-level object required")
    return value


def _reject_unknown_authority_keys(value: Mapping[str, Any], allowed: set[str]) -> None:
    for key in value:
        if key not in allowed:
            raise ContractError(f"hermes_base_v4_unknown_authority_key: {key}")


def validate_source_only_contract(contract: Mapping[str, Any]) -> None:
    _reject_unknown_authority_keys(
        contract,
        {
            "schema", "status", "source", "requested_platform", "oci_index_digest",
            "resolved_build_identity", "build_gate",
        },
    )
    source_value = contract.get("source")
    if isinstance(source_value, Mapping):
        _reject_unknown_authority_keys(source_value, {"tag", "commit", "tree"})
    build_gate_value = contract.get("build_gate")
    if isinstance(build_gate_value, Mapping):
        _reject_unknown_authority_keys(build_gate_value, {"receipt_requirement"})
    for key in ("schema", "status", "source", "requested_platform", "oci_index_digest"):
        if contract.get(key) != EXPECTED[key]:
            raise ContractError(f"hermes_base_v4_contract_mismatch: {key}")
    source = contract["source"]
    if not isinstance(source, Mapping) or not OID.fullmatch(str(source.get("commit", ""))) or not OID.fullmatch(str(source.get("tree", ""))):
        raise ContractError("hermes_base_v4_contract_mismatch: exact source commit and tree required")
    if not SHA256.fullmatch(str(contract["oci_index_digest"])):
        raise ContractError("hermes_base_v4_contract_mismatch: OCI index digest required")
    resolved = contract.get("resolved_build_identity")
    if not isinstance(resolved, Mapping) or set(resolved) != set(UNRESOLVED_FIELDS):
        raise ContractError("hermes_base_v4_contract_mismatch: exact resolved identity fields required")
    for field in UNRESOLVED_FIELDS:
        if resolved[field] is not None:
            raise ContractError(f"hermes_base_v4_unresolved_field_must_be_null: {field}")
    if "OCI-index digests are not platform-manifest, config, or local image IDs" not in str(contract.get("build_gate", "")):
        raise ContractError("hermes_base_v4_contract_mismatch: anti-conflation gate required")


def require_resolved_build_receipt(contract: Mapping[str, Any]) -> None:
    """Always reject this v4 source-only lock as a runtime/build-consumer input."""
    validate_source_only_contract(contract)
    unresolved = contract["resolved_build_identity"]
    missing = [field for field in UNRESOLVED_FIELDS if unresolved[field] is None]
    if missing:
        raise ContractError("hermes_base_v4_build_receipt_required: " + ",".join(missing))
    raise ContractError("hermes_base_v4_source_only_lock_cannot_be_consumed")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lock", type=Path, default=DEFAULT_LOCK)
    parser.add_argument("--check-only", action="store_true")
    parser.add_argument("--require-resolved", action="store_true")
    args = parser.parse_args()
    contract = load_contract(args.lock)
    try:
        if args.require_resolved:
            require_resolved_build_receipt(contract)
        else:
            validate_source_only_contract(contract)
    except ContractError as exc:
        print(str(exc))
        return 1
    print("hermes_base_v4_source_only_contract_valid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
