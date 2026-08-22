#!/usr/bin/env python3
"""Fail-closed admission for the fleet Hermes-base rebind packet."""
import argparse
import json
import re
import subprocess
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


def load_json(path: Path, label: str) -> dict:
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"{label}: {exc}")
    if not isinstance(value, dict):
        fail(f"{label} must be an object")
    return value


def admit(lock_path: Path, v3_lock_path: Path, receipt_path: Path, inspect_command: str, expected_image_id: str | None) -> dict:
    fleet = load(lock_path)
    image_id = fleet["base"]["local_image_id"]
    if not image_id:
        fail("local image ID is unbound; build is quarantined")
    if expected_image_id is not None and expected_image_id != image_id:
        fail("supplied base image ID does not bind admitted rebind lock")
    if not IMAGE_ID.fullmatch(image_id):
        fail("admitted local image ID malformed")
    try:
        from hermes_base_v3 import load_lock, verify_receipt
        v3_lock = load_lock(v3_lock_path)
        receipt = load_json(receipt_path, "v3 receipt")
        verify_receipt(receipt, v3_lock)
    except (ImportError, OSError, ValueError, json.JSONDecodeError) as exc:
        fail(f"v3 receipt verification failed: {exc}")
    source, v3_source = fleet["base"]["source"], v3_lock["source"]
    if fleet["base"]["tag"] != v3_lock["image"]["final_tag"]:
        fail("fleet tag does not bind v3 final tag")
    if source["commit"] != v3_source["commit"] or source["tree"] != v3_source["tree"] or source["archive_sha256"] != v3_source["archive"]["sha256"]:
        fail("fleet source tuple does not bind v3 lock")
    if receipt["final_tag"] != fleet["base"]["tag"] or receipt["final_image_id"] != image_id:
        fail("v3 receipt final tag or image ID does not bind fleet lock")
    if receipt["source_commit"] != source["commit"] or receipt["source_tree"] != source["tree"] or receipt["archive_sha256"] != source["archive_sha256"]:
        fail("v3 receipt source tuple does not bind fleet lock")
    try:
        observed = subprocess.run([inspect_command, "image", "inspect", fleet["base"]["tag"], "--format", "{{.Id}}"], text=True, capture_output=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError) as exc:
        fail(f"docker tag inspection failed: {exc}")
    if observed != image_id:
        fail("observed docker tag does not resolve to admitted image ID")
    return {"tag": fleet["base"]["tag"], "image_id": image_id, "source": source}


def main() -> int:
    # Preserve the original no-subcommand validator invocation for existing callers.
    if len(sys.argv) > 1 and sys.argv[1].startswith("-"):
        parser = argparse.ArgumentParser()
        parser.add_argument("--lock", required=True, type=Path)
        parser.add_argument("--require-local-image-id", action="store_true")
        args = parser.parse_args()
        args.command = "validate"
    else:
        parser = argparse.ArgumentParser()
        sub = parser.add_subparsers(dest="command", required=True)
        legacy = sub.add_parser("validate")
        legacy.add_argument("--lock", required=True, type=Path)
        legacy.add_argument("--require-local-image-id", action="store_true")
        admission = sub.add_parser("admit")
        admission.add_argument("--lock", required=True, type=Path)
        admission.add_argument("--v3-lock", required=True, type=Path)
        admission.add_argument("--receipt", required=True, type=Path)
        admission.add_argument("--inspect-command", required=True)
        admission.add_argument("--expected-image-id")
        args = parser.parse_args()
    try:
        if args.command == "validate":
            data = load(args.lock)
            if args.require_local_image_id and not data["base"]["local_image_id"]:
                fail("local image ID is unbound; build is quarantined")
            print("fleet_hermes_918b_rebind_lock_ok")
        else:
            result = admit(args.lock, args.v3_lock, args.receipt, args.inspect_command, args.expected_image_id)
            print(f"fleet_hermes_918b_rebind_admission_ok tag={result['tag']} image_id={result['image_id']}")
    except ValueError as exc:
        print(exc, file=sys.stderr)
        return 65
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
