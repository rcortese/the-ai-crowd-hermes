#!/usr/bin/env python3
"""Validate the approved protected Hermes 74 A2A base-consumption lock."""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
LOCK_PATH = ROOT / "ops/manifests/protected-hermes-a2a-base.lock.json"
IMAGE_ID = re.compile(r"sha256:[0-9a-f]{64}\Z")
REVISION = re.compile(r"[0-9a-f]{40}\Z")
APPROVED_IMAGE = "the-ai-crowd/hermes-base:g1-74a48e796a5-amd64"
APPROVED_IMAGE_ID = "sha256:4897db2b99c5c20c8b3561a16a4667c273d5862fe9a65b733aaf38bebfe3a045"
APPROVED_SOURCE_REVISION = "74a48e796a5c01c569aba90b2577123124dd2128"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check-only", action="store_true", help="accepted for explicit source-only validation")
    args = parser.parse_args()
    lock = json.loads(LOCK_PATH.read_text(encoding="utf-8"))

    if lock.get("schema") != "the-ai-crowd-hermes.protected-a2a-base-lock.v2":
        raise SystemExit("protected_a2a_base_lock_failed: unexpected schema")
    if lock.get("status") != "approved-protected-base-consumption":
        raise SystemExit("protected_a2a_base_lock_failed: approved protected base consumption required")
    base = lock.get("protected_base")
    if not isinstance(base, dict):
        raise SystemExit("protected_a2a_base_lock_failed: protected base record required")
    if not IMAGE_ID.fullmatch(base.get("image_id", "")):
        raise SystemExit("protected_a2a_base_lock_failed: immutable sha256 image ID required")
    if not REVISION.fullmatch(base.get("source_revision", "")):
        raise SystemExit("protected_a2a_base_lock_failed: exact protected source revision required")
    if base != {
        "image": APPROVED_IMAGE,
        "image_id": APPROVED_IMAGE_ID,
        "source_revision": APPROVED_SOURCE_REVISION,
    }:
        raise SystemExit("protected_a2a_base_lock_failed: protected base does not match approved Hermes 74 receipt")
    if lock.get("persona_consumers") != ["moss", "denholm"]:
        raise SystemExit("protected_a2a_base_lock_failed: Moss and Denholm must be the only protected-base consumers")
    transport = lock.get("a2a_transport", "")
    if "five-tool" not in transport or "no runtime overlay" not in transport:
        raise SystemExit("protected_a2a_base_lock_failed: fixed five-tool no-overlay transport statement required")
    if args.check_only:
        print("protected_a2a_base_lock_valid")
    else:
        print("protected_a2a_base_lock_valid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
