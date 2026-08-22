#!/usr/bin/env python3
"""Fail-closed source contract for the fleet Hermes-base rebind packet."""
import argparse
import json
import re
import sys
from pathlib import Path

SHA40 = re.compile(r"^[0-9a-f]{40}$")
SHA64 = re.compile(r"^[0-9a-f]{64}$")
IMAGE_ID = re.compile(r"^sha256:[0-9a-f]{64}$")
TAG = re.compile(r"^the-ai-crowd/hermes-base:918b36785653$")
EXPECTED = {
    "repository": "git@github.com:rcortese/hermes-agent.git",
    "commit": "918b36785653ec291806558e30b302b8cad10777",
    "tree": "817966c265522f8a7ae07473284451e17f1e683a",
    "archive_sha256": "8a26e82ce96b4b5429d0321e19ddb0b01bed9d5925ab2a0ecc89e9201bfe6aee",
}


def fail(message: str) -> None:
    raise ValueError(f"fleet_rebind_lock_failed: {message}")


def load(lock_path: Path) -> dict:
    try:
        data = json.loads(lock_path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        fail(str(exc))
    if data.get("schema") != "the-ai-crowd.fleet-hermes-918b-rebind-lock.v1":
        fail("unexpected schema")
    if data.get("status") != "source-only-quarantined":
        fail("source-only quarantine status required")
    base = data.get("base")
    if not isinstance(base, dict) or not TAG.fullmatch(base.get("tag", "")):
        fail("exact v3 final tag required")
    source = base.get("source")
    if not isinstance(source, dict) or source != EXPECTED:
        fail("exact 918b source tuple required")
    if not SHA40.fullmatch(source["commit"]) or not SHA40.fullmatch(source["tree"]) or not SHA64.fullmatch(source["archive_sha256"]):
        fail("malformed source tuple")
    if base.get("v3_lock") != "ops/manifests/hermes-base-v3.lock.json":
        fail("exact v3 lock path required")
    if data.get("persona_builders") != ["moss", "jen", "denholm", "roy", "richmond", "the-elders"]:
        fail("exact persona builder set required")
    overlay = data.get("a2a_overlay")
    if not isinstance(overlay, dict) or overlay.get("disposition") != "quarantined" or not isinstance(overlay.get("reason"), str):
        fail("A2A overlay quarantine required")
    image_id = base.get("local_image_id")
    if image_id is not None and not IMAGE_ID.fullmatch(image_id):
        fail("local image ID must be null or immutable sha256")
    return data


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--lock", required=True, type=Path)
    parser.add_argument("--require-local-image-id", action="store_true")
    args = parser.parse_args()
    try:
        data = load(args.lock)
        image_id = data["base"]["local_image_id"]
        if args.require_local_image_id and not image_id:
            fail("local image ID is unbound; build is quarantined")
    except ValueError as exc:
        print(exc, file=sys.stderr)
        return 65
    print("fleet_hermes_918b_rebind_lock_ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
