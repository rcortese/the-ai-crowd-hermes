#!/usr/bin/env python3
"""Atomically bind Persona API topology with a hash-bound reversible preimage."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
import tempfile
from pathlib import Path
from typing import Any

import yaml

SNAPSHOT_VERSION = 1


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def load_mapping(path: Path, *, json_only: bool = False) -> dict[str, Any]:
    data = json.loads(path.read_text()) if json_only else yaml.safe_load(path.read_text())
    if not isinstance(data, dict):
        raise ValueError(f"{path}: expected mapping")
    return data


def desired_binding(topology: dict[str, Any], persona: str) -> tuple[dict[str, Any], tuple[str, ...]]:
    personas = topology.get("personas")
    platforms = topology.get("session_platforms")
    if not isinstance(personas, dict) or persona not in personas:
        raise ValueError(f"unknown persona: {persona}")
    if not isinstance(platforms, list) or not platforms or not all(isinstance(v, str) and v for v in platforms):
        raise ValueError("topology session_platforms must be a non-empty string list")
    spec = personas[persona]
    inbound = spec.get("inbound_callers")
    outbound = spec.get("outbound_targets")
    if not isinstance(inbound, dict) or not isinstance(outbound, dict):
        raise ValueError(f"{persona}: invalid topology entry")
    callers: dict[str, Any] = {}
    for caller, token_env in inbound.items():
        if not isinstance(caller, str) or not isinstance(token_env, str):
            raise ValueError(f"{persona}: invalid inbound caller")
        callers[caller] = {"allow_targets": [persona]}
    targets: dict[str, Any] = {}
    for target, target_spec in outbound.items():
        if not isinstance(target_spec, dict):
            raise ValueError(f"{persona}: invalid outbound target {target}")
        url = target_spec.get("url")
        token_env = target_spec.get("token_env")
        if not isinstance(url, str) or not url.startswith("http://") or not isinstance(token_env, str):
            raise ValueError(f"{persona}: invalid outbound target {target}")
        targets[target] = {"url": url}
    return {
        "self_target": persona,
        "inbound": {"callers": callers},
        "outbound": {"targets": targets},
    }, tuple(platforms)


def apply_binding(config: dict[str, Any], binding: dict[str, Any], platforms: tuple[str, ...]) -> dict[str, Any]:
    config["persona_api"] = binding
    platform_toolsets = config.setdefault("platform_toolsets", {})
    if not isinstance(platform_toolsets, dict):
        raise ValueError("config.platform_toolsets must be a mapping")
    for platform in platforms:
        configured = platform_toolsets.get(platform, ["hermes-core"])
        if not isinstance(configured, list) or not all(isinstance(value, str) for value in configured):
            raise ValueError(f"platform toolsets for {platform} must be a string list")
        if "persona" not in configured:
            configured.append("persona")
        platform_toolsets[platform] = configured
    return config


def fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def write_exclusive(path: Path, data: bytes, mode: int = 0o600) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
    except Exception:
        try:
            path.unlink()
        except FileNotFoundError:
            pass
        raise


def replace_config(path: Path, data: bytes, mode: int, uid: int, gid: int) -> None:
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, mode)
        os.chown(temporary, uid, gid)
        os.replace(temporary, path)
        fsync_directory(path.parent)
    finally:
        if temporary.exists():
            temporary.unlink()


def create_snapshot(config_path: Path, preimage: bytes, postimage: bytes, snapshot_dir: Path, persona: str) -> dict[str, Any]:
    if snapshot_dir.exists() or snapshot_dir.is_symlink():
        raise ValueError("snapshot directory must not already exist")
    snapshot_dir.mkdir(mode=0o700)
    config_stat = config_path.stat(follow_symlinks=False)
    manifest = {
        "version": SNAPSHOT_VERSION,
        "persona": persona,
        "config_path": str(config_path.resolve(strict=True)),
        "preimage_sha256": sha256_bytes(preimage),
        "postimage_sha256": sha256_bytes(postimage),
        "mode": stat.S_IMODE(config_stat.st_mode),
        "uid": config_stat.st_uid,
        "gid": config_stat.st_gid,
    }
    try:
        write_exclusive(snapshot_dir / "config.yaml.preimage", preimage)
        write_exclusive(
            snapshot_dir / "manifest.json",
            (json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n").encode(),
        )
        fsync_directory(snapshot_dir)
        # The files are not a durable preimage until the newly created
        # snapshot directory entry itself is durable in its parent. This
        # ordering must complete before replace_config can publish postimage.
        fsync_directory(snapshot_dir.parent)
    except Exception:
        for child in snapshot_dir.iterdir():
            child.unlink()
        snapshot_dir.rmdir()
        raise
    return manifest


def materialize_config(config_path: Path, topology_path: Path, persona: str, snapshot_dir: Path) -> dict[str, Any]:
    if config_path.is_symlink() or not config_path.is_file():
        raise ValueError("config must be an existing regular file, not a symlink")
    preimage = config_path.read_bytes()
    config = load_mapping(config_path)
    topology = load_mapping(topology_path, json_only=True)
    binding, platforms = desired_binding(topology, persona)
    postimage = yaml.safe_dump(apply_binding(config, binding, platforms), sort_keys=False).encode()
    config_stat = config_path.stat(follow_symlinks=False)
    manifest = create_snapshot(config_path, preimage, postimage, snapshot_dir, persona)
    replace_config(
        config_path,
        postimage,
        stat.S_IMODE(config_stat.st_mode),
        config_stat.st_uid,
        config_stat.st_gid,
    )
    return manifest


def restore_config(config_path: Path, snapshot_dir: Path) -> dict[str, Any]:
    if config_path.is_symlink() or not config_path.is_file():
        raise ValueError("config must be an existing regular file, not a symlink")
    if snapshot_dir.is_symlink() or not snapshot_dir.is_dir():
        raise ValueError("snapshot must be a real directory")
    manifest_path = snapshot_dir / "manifest.json"
    preimage_path = snapshot_dir / "config.yaml.preimage"
    if manifest_path.is_symlink() or preimage_path.is_symlink() or not manifest_path.is_file() or not preimage_path.is_file():
        raise ValueError("snapshot files must be regular files")
    manifest = json.loads(manifest_path.read_text())
    required = {"version", "persona", "config_path", "preimage_sha256", "postimage_sha256", "mode", "uid", "gid"}
    if not isinstance(manifest, dict) or set(manifest) != required or manifest["version"] != SNAPSHOT_VERSION:
        raise ValueError("invalid snapshot manifest")
    if manifest["config_path"] != str(config_path.resolve(strict=True)):
        raise ValueError("snapshot config path mismatch")
    preimage = preimage_path.read_bytes()
    if sha256_bytes(preimage) != manifest["preimage_sha256"]:
        raise ValueError("snapshot preimage hash mismatch")
    if sha256_bytes(config_path.read_bytes()) != manifest["postimage_sha256"]:
        raise ValueError("current config is not the snapshot-bound postimage")
    mode, uid, gid = manifest["mode"], manifest["uid"], manifest["gid"]
    if not all(isinstance(value, int) and value >= 0 for value in (mode, uid, gid)):
        raise ValueError("invalid snapshot ownership or mode")
    replace_config(config_path, preimage, mode, uid, gid)
    return manifest


def check_binding(config_path: Path, topology_path: Path, persona: str) -> None:
    if config_path.is_symlink() or not config_path.is_file():
        raise ValueError("config must be an existing regular file, not a symlink")
    original = config_path.read_text()
    config = load_mapping(config_path)
    topology = load_mapping(topology_path, json_only=True)
    binding, platforms = desired_binding(topology, persona)
    rendered = yaml.safe_dump(apply_binding(config, binding, platforms), sort_keys=False)
    if rendered != original:
        raise ValueError("persona_api binding drift")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--topology", type=Path)
    parser.add_argument("--persona")
    parser.add_argument("--snapshot-dir", type=Path)
    parser.add_argument("--restore-from", type=Path)
    parser.add_argument("--check-only", action="store_true")
    args = parser.parse_args()
    try:
        if args.restore_from:
            if args.topology or args.persona or args.snapshot_dir or args.check_only:
                raise ValueError("restore mode accepts only --config and --restore-from")
            manifest = restore_config(args.config, args.restore_from)
            print(f"persona_api_restored persona={manifest['persona']}")
            return 0
        if not args.topology or not args.persona:
            raise ValueError("materialize/check requires --topology and --persona")
        if args.check_only:
            if args.snapshot_dir:
                raise ValueError("check-only does not accept --snapshot-dir")
            check_binding(args.config, args.topology, args.persona)
            print(f"persona_api_binding_ok persona={args.persona}")
            return 0
        if not args.snapshot_dir:
            raise ValueError("materialization requires --snapshot-dir")
        materialize_config(args.config, args.topology, args.persona, args.snapshot_dir)
        print(f"persona_api_materialized persona={args.persona}")
        return 0
    except (OSError, ValueError, json.JSONDecodeError, yaml.YAMLError) as exc:
        print(f"persona_api_materializer_error: {exc}", file=os.sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
