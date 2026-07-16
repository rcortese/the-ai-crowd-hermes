#!/usr/bin/env python3
"""Single-use guardian for the Moss admission-fence bootstrap transition."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from typing import Any

DEPLOYMENT_ROOT = Path("/mnt/user/appdata/the-ai-crowd")
CANONICAL_COMPOSE = DEPLOYMENT_ROOT / "compose.yaml"
CANONICAL_ENV = DEPLOYMENT_ROOT / ".env"
CANONICAL_CONTAINER = "the-ai-crowd-moss-1"
CANONICAL_SERVICE = "moss"
CADDY_NETWORK = "local-llm-net"
LOCK_PATH = DEPLOYMENT_ROOT / "state/shared/moss-profile-bootstrap.lock"
SUPERVISOR_CONFIG = "/etc/supervisor/conf.d/moss-all-in-one.conf"


class GuardianError(RuntimeError):
    pass


def sha256_bytes(body: bytes) -> str:
    return hashlib.sha256(body).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def require_regular(path: Path, parent: Path | None = None) -> Path:
    if not path.is_absolute() or path.is_symlink() or not path.is_file():
        raise GuardianError(f"not a regular absolute file: {path}")
    resolved = path.resolve(strict=True)
    if resolved != path:
        raise GuardianError(f"symlink component in file path: {path}")
    metadata = path.stat()
    if metadata.st_uid != 0 or metadata.st_mode & 0o022:
        raise GuardianError(f"file must be root-owned and not group/world-writable: {path}")
    if parent is not None and parent.resolve(strict=True) not in resolved.parents:
        raise GuardianError(f"file outside state: {path}")
    return resolved


def require_dir(path: Path) -> Path:
    if not path.is_absolute() or path.is_symlink() or not path.is_dir() or path.resolve(strict=True) != path:
        raise GuardianError(f"not a real absolute directory: {path}")
    metadata = path.stat()
    if metadata.st_uid != 0 or metadata.st_mode & 0o022:
        raise GuardianError(f"directory must be root-owned and not group/world-writable: {path}")
    return path


def read_json(path: Path, parent: Path | None = None) -> dict[str, Any]:
    require_regular(path, parent)
    body = json.loads(path.read_text())
    if not isinstance(body, dict):
        raise GuardianError(f"JSON object required: {path}")
    return body


def fsync_dir(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def atomic_json(path: Path, body: dict[str, Any]) -> None:
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(tmp, flags, 0o600)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(body, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp, path)
        fsync_dir(path.parent)
    finally:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass


class Guardian:
    def __init__(self, state: Path) -> None:
        self.state = require_dir(state)
        self.package_path = self.state / "package.json"
        self.ready_path = self.state / "authorization.ready.json"
        self.consumed_path = self.state / "authorization.consumed.json"
        self.status_path = self.state / "status.json"
        self.package = read_json(self.package_path, self.state)
        self.transition_started = False
        self.drain_written = False
        self.network_disconnected = False
        self.webui_stopped = False
        self.sleep = float(os.getenv("MOSS_BOOTSTRAP_POLL_SECONDS", "1"))
        self.idle_confirm = float(os.getenv("MOSS_BOOTSTRAP_IDLE_CONFIRM_SECONDS", "5"))
        self.timeout = float(os.getenv("MOSS_BOOTSTRAP_TIMEOUT_SECONDS", "180"))

    def status(self, state: str, **extra: Any) -> None:
        atomic_json(self.status_path, {"schema": "moss-fence-bootstrap-status/v1", "state": state, **extra})

    def run(self, args: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(args, text=True, capture_output=True)
        if check and result.returncode:
            raise GuardianError(f"command failed ({result.returncode}): {args[0]} {args[1] if len(args) > 1 else ''}")
        return result

    def docker(self, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
        return self.run(["docker", *args], check=check)

    def compose(self, override: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
        return self.docker(
            "compose", "--project-directory", str(DEPLOYMENT_ROOT), "--env-file", str(CANONICAL_ENV),
            "-f", str(CANONICAL_COMPOSE), "-f", str(override), *args, check=check,
        )

    def validate_package(self) -> None:
        p = self.package
        if p.get("schema") != "moss-fence-bootstrap-package/v1":
            raise GuardianError("invalid package schema")
        fixed = {
            "container": CANONICAL_CONTAINER,
            "service": CANONICAL_SERVICE,
            "deployment_root": str(DEPLOYMENT_ROOT),
            "compose_file": str(CANONICAL_COMPOSE),
            "env_file": str(CANONICAL_ENV),
        }
        for key, expected in fixed.items():
            if p.get(key) != expected:
                raise GuardianError(f"canonical package mismatch: {key}")
        for key in ("expected_container_id", "expected_live_image_id", "bootstrap_image_id"):
            value = str(p.get(key, ""))
            if key.endswith("image_id") and (not value.startswith("sha256:") or len(value) != 71):
                raise GuardianError(f"invalid {key}")
            if key == "expected_container_id" and len(value) != 64:
                raise GuardianError("invalid expected_container_id")
        for name in ("bootstrap_override", "rollback_override"):
            path = require_regular(Path(str(p.get(name, ""))), self.state)
            if sha256_file(path) != p.get(f"{name}_sha256"):
                raise GuardianError(f"{name} hash mismatch")
        if sha256_file(CANONICAL_COMPOSE) != p.get("compose_sha256"):
            raise GuardianError("compose hash mismatch")
        if sha256_file(CANONICAL_ENV) != p.get("env_sha256"):
            raise GuardianError("env hash mismatch")
        for mode in ("bootstrap", "rollback"):
            override = Path(str(p[f"{mode}_override"]))
            rendered = self.compose(override, "config").stdout.encode()
            if sha256_bytes(rendered) != p.get(f"{mode}_render_sha256"):
                raise GuardianError(f"{mode} render hash mismatch")

    def validate_authorization(self) -> None:
        if self.consumed_path.exists() or self.consumed_path.is_symlink():
            raise GuardianError("authorization already consumed")
        receipt = read_json(self.ready_path, self.state)
        if receipt.get("schema") != "moss-fence-bootstrap-authorization/v1":
            raise GuardianError("invalid authorization schema")
        if receipt.get("package_sha256") != sha256_file(self.package_path):
            raise GuardianError("authorization package hash mismatch")
        nonce = receipt.get("nonce")
        if not isinstance(nonce, str) or len(nonce) < 16 or not nonce.replace("-", "").isalnum():
            raise GuardianError("invalid authorization nonce")
        raw_expiry = str(receipt.get("expires_at", ""))
        try:
            expiry = datetime.fromisoformat(raw_expiry.replace("Z", "+00:00"))
        except ValueError as exc:
            raise GuardianError("invalid authorization expiry") from exc
        if expiry.tzinfo is None or expiry <= datetime.now(timezone.utc):
            raise GuardianError("authorization expired")

    def burn_authorization(self) -> None:
        os.replace(self.ready_path, self.consumed_path)
        with self.consumed_path.open("rb") as stream:
            os.fsync(stream.fileno())
        fsync_dir(self.state)
        self.status("activation_uncertain", authorization_consumed=True)

    def inspect_live(self) -> tuple[str, str, str, str]:
        raw = self.docker(
            "inspect", CANONICAL_CONTAINER,
            "--format", "{{.Id}}|{{.Image}}|{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}",
        ).stdout.strip()
        parts = raw.split("|")
        if len(parts) != 4:
            raise GuardianError("unexpected live inspect shape")
        return tuple(parts)  # type: ignore[return-value]

    def assert_cas(self, *, require_healthy: bool) -> None:
        container_id, image_id, state, health = self.inspect_live()
        if container_id != self.package["expected_container_id"] or image_id != self.package["expected_live_image_id"]:
            raise GuardianError("live container CAS mismatch")
        if state != "running" or (require_healthy and health != "healthy"):
            raise GuardianError("live container not healthy")
        actual = self.docker("image", "inspect", self.package["bootstrap_image_id"], "--format", "{{.Id}}").stdout.strip()
        if actual != self.package["bootstrap_image_id"]:
            raise GuardianError("bootstrap image CAS mismatch")

    def webui_health(self) -> dict[str, Any]:
        result = self.docker(
            "exec", CANONICAL_CONTAINER, "python3", "-c",
            "import json,urllib.request; print(json.dumps(json.load(urllib.request.urlopen('http://127.0.0.1:8787/health',timeout=3))))",
        )
        body = json.loads(result.stdout)
        if not isinstance(body, dict):
            raise GuardianError("invalid WebUI health")
        return body

    def idle_once(self) -> bool:
        try:
            body = self.webui_health()
            return body.get("status") == "ok" and int(body.get("active_runs", -1)) == 0 and int(body.get("active_streams", -1)) == 0
        except (GuardianError, ValueError, TypeError, json.JSONDecodeError):
            return False

    def sustained_idle(self) -> bool:
        if not self.idle_once():
            return False
        time.sleep(self.idle_confirm)
        return self.idle_once()

    def write_gateway_drain(self) -> None:
        code = (
            "from pathlib import Path; from gateway.drain_control import write_drain_request; "
            "write_drain_request(principal='moss-fence-bootstrap',suppress_notification=True,home=Path('/opt/data'))"
        )
        self.docker("exec", "--user", "99:100", CANONICAL_CONTAINER, "/opt/hermes/.venv/bin/python3", "-c", code)
        self.drain_written = True

    def clear_gateway_drain(self) -> None:
        code = "from pathlib import Path; from gateway.drain_control import clear_drain_request; clear_drain_request(home=Path('/opt/data'))"
        self.docker("exec", "--user", "99:100", CANONICAL_CONTAINER, "/opt/hermes/.venv/bin/python3", "-c", code, check=False)
        self.drain_written = False

    def gateway_status(self) -> dict[str, Any]:
        code = (
            "import json; from pathlib import Path; from gateway.status import read_runtime_status; "
            "print(json.dumps(read_runtime_status(Path('/opt/data/gateway_state.json')) or {}))"
        )
        result = self.docker("exec", "--user", "99:100", CANONICAL_CONTAINER, "/opt/hermes/.venv/bin/python3", "-c", code)
        body = json.loads(result.stdout)
        return body if isinstance(body, dict) else {}

    def wait_gateway_drained(self) -> None:
        deadline = time.monotonic() + self.timeout
        while time.monotonic() <= deadline:
            status = self.gateway_status()
            if status.get("gateway_state") == "draining" and int(status.get("active_agents") or 0) == 0:
                return
            time.sleep(self.sleep)
        raise GuardianError("gateway drain timeout")

    def fence_bootstrap_ingress(self) -> None:
        self.docker("network", "disconnect", CADDY_NETWORK, CANONICAL_CONTAINER)
        self.network_disconnected = True
        if not self.sustained_idle():
            raise GuardianError("post-disconnect WebUI activity")
        self.docker("exec", CANONICAL_CONTAINER, "supervisorctl", "-c", SUPERVISOR_CONFIG, "stop", "moss-webui")
        self.webui_stopped = True

    def restore_pretransition(self) -> None:
        if self.webui_stopped:
            self.docker("exec", CANONICAL_CONTAINER, "supervisorctl", "-c", SUPERVISOR_CONFIG, "start", "moss-webui", check=False)
        if self.network_disconnected:
            self.docker("network", "connect", "--alias", "moss", CADDY_NETWORK, CANONICAL_CONTAINER, check=False)
        if self.drain_written:
            self.clear_gateway_drain()

    def wait_bootstrap_ready(self, expected_image: str, *, require_fence_field: bool) -> None:
        deadline = time.monotonic() + self.timeout
        while time.monotonic() <= deadline:
            try:
                _, image, state, health = self.inspect_live()
                body = self.webui_health()
                gateway = self.gateway_status()
                fence_ok = body.get("admission_fenced") is False if require_fence_field else True
                if image == expected_image and state == "running" and health == "healthy" and body.get("status") == "ok" and fence_ok and gateway.get("gateway_state") in {"running", "starting"}:
                    return
            except (GuardianError, ValueError, TypeError, json.JSONDecodeError):
                pass
            time.sleep(self.sleep)
        raise GuardianError("readiness timeout")

    def rollback(self) -> bool:
        self.status("rollback_uncertain")
        override = Path(self.package["rollback_override"])
        result = self.compose(override, "up", "-d", "--no-deps", "--force-recreate", "--wait", "--wait-timeout", "180", CANONICAL_SERVICE, check=False)
        if result.returncode:
            self.status("rollback_failed", stage="compose")
            return False
        try:
            self.wait_bootstrap_ready(self.package["expected_live_image_id"], require_fence_field=False)
            self.clear_gateway_drain()
        except GuardianError:
            self.status("rollback_failed", stage="readiness")
            return False
        self.status("rollback_ready")
        return True

    def activate(self) -> None:
        self.validate_package()
        self.validate_authorization()
        LOCK_PATH.parent.mkdir(parents=True, exist_ok=True)
        lock_fd = os.open(LOCK_PATH, os.O_WRONLY | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
        try:
            try:
                fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as exc:
                raise GuardianError("lifecycle lock busy") from exc
            self.assert_cas(require_healthy=True)
            if not self.sustained_idle():
                raise GuardianError("initial WebUI activity")
            self.burn_authorization()
            try:
                self.write_gateway_drain()
                self.wait_gateway_drained()
                self.fence_bootstrap_ingress()
                self.assert_cas(require_healthy=False)
                self.transition_started = True
                override = Path(self.package["bootstrap_override"])
                result = self.compose(override, "up", "-d", "--no-deps", "--force-recreate", "--wait", "--wait-timeout", "180", CANONICAL_SERVICE, check=False)
                if result.returncode:
                    raise GuardianError("bootstrap compose failed")
                self.network_disconnected = False
                self.webui_stopped = False
                self.drain_written = False
                self.wait_bootstrap_ready(self.package["bootstrap_image_id"], require_fence_field=True)
                self.clear_gateway_drain()
                self.status("bootstrap_ready")
            except GuardianError:
                if self.transition_started:
                    self.rollback()
                else:
                    self.restore_pretransition()
                    self.status("activation_failed_pretransition")
                raise
        finally:
            os.close(lock_fd)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--execute", action="store_true")
    args = parser.parse_args(argv)
    if not args.execute:
        print("refusing lifecycle mutation without --execute", file=sys.stderr)
        return 2
    try:
        Guardian(args.state).activate()
        return 0
    except (GuardianError, OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"guardian blocked: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
