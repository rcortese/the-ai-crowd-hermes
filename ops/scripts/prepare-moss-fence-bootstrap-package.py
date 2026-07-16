#!/usr/bin/env python3
"""Prepare a root-only, non-authorized Moss fence-bootstrap package."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
from typing import Any

ROOT = Path("/mnt/user/appdata/the-ai-crowd")
COMPOSE = ROOT / "compose.yaml"
ENV_FILE = ROOT / ".env"
CONTAINER = "the-ai-crowd-moss-1"
SERVICE = "moss"


def digest(body: bytes) -> str:
    return hashlib.sha256(body).hexdigest()


def file_digest(path: Path) -> str:
    return digest(path.read_bytes())


def atomic_json(path: Path, body: dict[str, Any]) -> None:
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    tmp = Path(tmp_name)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(body, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass


def atomic_text(path: Path, body: str) -> None:
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    tmp = Path(tmp_name)
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(body)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass


def command(*argv: str) -> str:
    return subprocess.check_output(argv, text=True)


def render(override: Path) -> bytes:
    return subprocess.check_output(
        [
            "docker", "compose", "--project-directory", str(ROOT), "--env-file", str(ENV_FILE),
            "-f", str(COMPOSE), "-f", str(override), "config",
        ]
    )


def image_id(value: str) -> str:
    if not value.startswith("sha256:") or len(value) != 71:
        raise ValueError("immutable image ID required")
    actual = command("docker", "image", "inspect", value, "--format", "{{.Id}}").strip()
    if actual != value:
        raise ValueError("image ID CAS mismatch")
    return value


def commit_id(value: str) -> str:
    if len(value) != 40 or any(char not in "0123456789abcdef" for char in value):
        raise ValueError("full lowercase commit required")
    return value


def prepare(state: Path, bootstrap_image: str, bootstrap_source_commit: str, guardian_commit: str) -> dict[str, Any]:
    if not state.is_absolute() or state.is_symlink() or state.exists():
        raise ValueError("state must be a new absolute non-symlink path")
    parent = state.parent.resolve(strict=True)
    if parent != state.parent or parent.stat().st_uid != 0 or parent.stat().st_mode & 0o022:
        raise ValueError("state parent must be a root-owned protected real directory")
    bootstrap_image = image_id(bootstrap_image)
    bootstrap_source_commit = commit_id(bootstrap_source_commit)
    guardian_commit = commit_id(guardian_commit)
    raw = command(
        "docker", "inspect", CONTAINER, "--format",
        "{{.Id}}|{{.Image}}|{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}",
    ).strip().split("|")
    if len(raw) != 4 or raw[2:] != ["running", "healthy"]:
        raise ValueError("live container not running/healthy")
    container_id, live_image = raw[:2]
    image_id(live_image)
    network = json.loads(
        command(
            "docker", "inspect", CONTAINER, "--format",
            '{{json (index .NetworkSettings.Networks "local-llm-net")}}',
        )
    )
    if not isinstance(network, dict) or not network.get("NetworkID") or not isinstance(network.get("Aliases"), list) or not network["Aliases"]:
        raise ValueError("Caddy network attachment is required")
    caddy_network_id = str(network["NetworkID"])
    caddy_network_aliases = sorted(set(str(item) for item in network["Aliases"]))
    state.mkdir(mode=0o700)
    try:
        bootstrap_override = state / "bootstrap.override.yaml"
        rollback_override = state / "rollback.override.yaml"
        atomic_text(
            bootstrap_override,
            "services:\n  moss:\n    image: \"" + bootstrap_image + "\"\n    environment:\n      HERMES_WEBUI_ADMISSION_FENCE: /opt/data/webui/admission-fence.json\n",
        )
        atomic_text(rollback_override, "services:\n  moss:\n    image: \"" + live_image + "\"\n")
        package = {
            "schema": "moss-fence-bootstrap-package/v1",
            "container": CONTAINER,
            "service": SERVICE,
            "deployment_root": str(ROOT),
            "compose_file": str(COMPOSE),
            "env_file": str(ENV_FILE),
            "expected_container_id": container_id,
            "expected_live_image_id": live_image,
            "bootstrap_image_id": bootstrap_image,
            "caddy_network_id": caddy_network_id,
            "caddy_network_aliases": caddy_network_aliases,
            "bootstrap_override": str(bootstrap_override),
            "rollback_override": str(rollback_override),
            "bootstrap_override_sha256": file_digest(bootstrap_override),
            "rollback_override_sha256": file_digest(rollback_override),
            "compose_sha256": file_digest(COMPOSE),
            "env_sha256": file_digest(ENV_FILE),
            "bootstrap_render_sha256": digest(render(bootstrap_override)),
            "rollback_render_sha256": digest(render(rollback_override)),
            "bootstrap_source_commit": bootstrap_source_commit,
            "guardian_commit": guardian_commit,
        }
        package_path = state / "package.json"
        atomic_json(package_path, package)
        atomic_json(
            state / "authorization.template.json",
            {
                "schema": "moss-fence-bootstrap-authorization/v1",
                "nonce": "REPLACE_WITH_SINGLE_USE_NONCE_AT_AUTHORIZATION_TIME",
                "expires_at": "REPLACE_WITH_SHORT_UTC_EXPIRY_AT_AUTHORIZATION_TIME",
                "package_sha256": file_digest(package_path),
            },
        )
        return {
            "state": str(state),
            "package_sha256": file_digest(package_path),
            "bootstrap_image_id": bootstrap_image,
            "expected_live_image_id": live_image,
            "expected_container_id": container_id,
            "authorization_ready": False,
        }
    except Exception:
        for path in state.iterdir():
            path.unlink()
        state.rmdir()
        raise


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--bootstrap-image-id", required=True)
    parser.add_argument("--bootstrap-source-commit", required=True)
    parser.add_argument("--guardian-commit", required=True)
    parser.add_argument("--execute", action="store_true")
    args = parser.parse_args()
    if not args.execute:
        print("refusing package write without --execute")
        return 2
    result = prepare(args.state, args.bootstrap_image_id, args.bootstrap_source_commit, args.guardian_commit)
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
