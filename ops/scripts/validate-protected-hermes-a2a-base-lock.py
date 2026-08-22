#!/usr/bin/env python3
"""Validate a future protected Hermes A2A base binding without materializing it."""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
LOCK_PATH = ROOT / "ops/manifests/protected-hermes-a2a-base.lock.json"
IMAGE_ID = re.compile(r"sha256:[0-9a-f]{64}\Z")
REVISION = re.compile(r"[0-9a-f]{40}\Z")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-id", help="immutable protected Hermes image ID")
    parser.add_argument("--source-revision", help="protected Hermes source commit")
    args = parser.parse_args()
    lock = json.loads(LOCK_PATH.read_text(encoding="utf-8"))

    if lock.get("schema") != "the-ai-crowd-hermes.protected-a2a-base-lock.v1":
        raise SystemExit("protected_a2a_base_lock_failed: unexpected schema")
    if lock.get("status") != "pending-external-protected-base-binding":
        raise SystemExit("protected_a2a_base_lock_failed: public scaffold must remain pending")
    if not REVISION.fullmatch(lock.get("expected_source_candidate", "")):
        raise SystemExit("protected_a2a_base_lock_failed: exact expected source candidate required")
    if lock.get("protected_base") != {"image_id": None, "source_revision": None}:
        raise SystemExit("protected_a2a_base_lock_failed: no unapproved protected base may be recorded")

    if args.base_id is None and args.source_revision is None:
        print("protected_a2a_base_lock_pending")
        return 0
    if args.base_id is None or args.source_revision is None:
        raise SystemExit("protected_a2a_base_lock_failed: base ID and source revision are paired inputs")
    if not IMAGE_ID.fullmatch(args.base_id):
        raise SystemExit("protected_a2a_base_lock_failed: immutable sha256 image ID required")
    if args.source_revision != lock["expected_source_candidate"]:
        raise SystemExit("protected_a2a_base_lock_failed: source revision does not match expected candidate")
    print("protected_a2a_base_input_valid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())