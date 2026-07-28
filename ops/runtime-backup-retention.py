#!/usr/bin/env python3
"""Manifest-aware, descriptor-anchored retention for runtime preimage sets."""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import stat
import time
from pathlib import Path

TERMINAL_STATES = {"activated", "rolled_back", "aborted"}
MANIFEST = "manifest.json"


def _read_all(fd: int) -> bytes:
    chunks: list[bytes] = []
    while True:
        part = os.read(fd, 1024 * 1024)
        if not part:
            return b"".join(chunks)
        chunks.append(part)


def _open_regular(dir_fd: int, name: str) -> int:
    if not name or name in {".", ".."} or "/" in name:
        raise ValueError("invalid_payload_name")
    fd = os.open(name, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW, dir_fd=dir_fd)
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        os.close(fd)
        raise ValueError("payload_not_regular")
    return fd


def _load_manifest(op_fd: int) -> tuple[dict[str, object], bytes]:
    fd = _open_regular(op_fd, MANIFEST)
    try:
        raw = _read_all(fd)
    finally:
        os.close(fd)
    data = json.loads(raw)
    if not isinstance(data, dict) or data.get("schema_version") != 1:
        raise ValueError("invalid_manifest_schema")
    return data, raw


def _eligible(op_name: str, op_fd: int, now: int) -> tuple[bool, list[str], str]:
    manifest, raw = _load_manifest(op_fd)
    if manifest.get("operation_id") != op_name:
        raise ValueError("operation_id_mismatch")
    if manifest.get("retained") is True:
        return False, [], "retained"
    if manifest.get("state") not in TERMINAL_STATES:
        return False, [], "nonterminal"
    expires_at = manifest.get("expires_at")
    if not isinstance(expires_at, int) or expires_at > now:
        return False, [], "unexpired"
    payloads = manifest.get("payloads")
    if not isinstance(payloads, list) or not payloads:
        raise ValueError("payloads_required")
    expected_names = {MANIFEST}
    names: list[str] = []
    for item in payloads:
        if not isinstance(item, dict):
            raise ValueError("invalid_payload_entry")
        name = item.get("path")
        expected_hash = item.get("sha256")
        expected_size = item.get("bytes")
        if not isinstance(name, str) or not isinstance(expected_hash, str) or len(expected_hash) != 64 or not isinstance(expected_size, int):
            raise ValueError("invalid_payload_metadata")
        fd = _open_regular(op_fd, name)
        try:
            content = _read_all(fd)
        finally:
            os.close(fd)
        if len(content) != expected_size or hashlib.sha256(content).hexdigest() != expected_hash:
            raise ValueError("payload_integrity_mismatch")
        expected_names.add(name)
        names.append(name)
    actual_names = set(os.listdir(op_fd))
    if actual_names != expected_names:
        raise ValueError("unexpected_operation_entries")
    return True, names, hashlib.sha256(raw).hexdigest()


def prune(root: Path, now: int, dry_run: bool) -> dict[str, object]:
    if root.is_symlink() or not root.is_dir():
        raise SystemExit("backup_root_missing_or_unsafe")
    root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW)
    deleted: list[dict[str, str]] = []
    preserved: list[dict[str, str]] = []
    rejected: list[dict[str, str]] = []
    try:
        lock_fd = os.open(".retention.lock", os.O_RDWR | os.O_CREAT | os.O_CLOEXEC | os.O_NOFOLLOW, 0o600, dir_fd=root_fd)
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            os.close(lock_fd)
            raise SystemExit("retention_lock_busy") from exc
        try:
            for name in sorted(os.listdir(root_fd)):
                if name == ".retention.lock":
                    continue
                if not name or name in {".", ".."} or "/" in name:
                    rejected.append({"operation_id": name, "reason": "invalid_operation_name"})
                    continue
                try:
                    op_fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW, dir_fd=root_fd)
                except OSError:
                    rejected.append({"operation_id": name, "reason": "operation_not_safe_directory"})
                    continue
                try:
                    eligible, payload_names, detail = _eligible(name, op_fd, now)
                    if not eligible:
                        preserved.append({"operation_id": name, "reason": detail})
                        continue
                    if dry_run:
                        preserved.append({"operation_id": name, "reason": "dry_run_eligible"})
                        continue
                    for payload_name in payload_names:
                        os.unlink(payload_name, dir_fd=op_fd)
                    os.unlink(MANIFEST, dir_fd=op_fd)
                    os.fsync(op_fd)
                    os.rmdir(name, dir_fd=root_fd)
                    os.fsync(root_fd)
                    deleted.append({"operation_id": name, "manifest_sha256": detail})
                except Exception as exc:  # fail closed per operation
                    rejected.append({"operation_id": name, "reason": str(exc)})
                finally:
                    os.close(op_fd)
        finally:
            os.close(lock_fd)
    finally:
        os.close(root_fd)
    result = {"status": "ok", "now": now, "dry_run": dry_run, "deleted": deleted, "preserved": preserved, "rejected": rejected}
    print(json.dumps(result, sort_keys=True))
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--now", type=int, default=None)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    prune(args.root, int(time.time()) if args.now is None else args.now, args.dry_run)


if __name__ == "__main__":
    main()
