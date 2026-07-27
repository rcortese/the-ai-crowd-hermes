#!/usr/bin/env python3
import importlib.util
import json
import os
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "ops/scripts/materialize-persona-api.py"
TOPOLOGY = ROOT / "ops/manifests/persona-api-topology.json"
PORTS = {"moss": 8648, "jen": 8642, "denholm": 8643, "roy": 8645, "richmond": 8646, "the-elders": 8647}


def invoke(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run([sys.executable, str(SCRIPT), *args], text=True, capture_output=True, check=check)


def load_module():
    spec = importlib.util.spec_from_file_location("persona_api_materializer_under_test", SCRIPT)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


with tempfile.TemporaryDirectory() as raw:
    temp = Path(raw)
    config = temp / "config.yaml"
    original = yaml.safe_dump({
        "platform_toolsets": {"telegram": ["hermes-core", "todo"]},
        "api_server": {"enabled": True},
    }, sort_keys=False).encode()
    config.write_bytes(original)
    os.chmod(config, 0o640)
    original_stat = config.stat()
    snapshot = temp / "snapshot"
    invoke("--config", str(config), "--topology", str(TOPOLOGY), "--persona", "jen", "--snapshot-dir", str(snapshot))
    data = yaml.safe_load(config.read_text())
    assert data["persona_api"] == {
        "self_target": "jen",
        "inbound": {"callers": {"moss": {"allow_targets": ["jen"]}}},
        "outbound": {"targets": {"moss": {"url": "http://moss:8648"}}},
    }
    for platform in ("api_server", "cron", "cli", "telegram"):
        assert "persona" in data["platform_toolsets"][platform]
    assert data["platform_toolsets"]["telegram"] == ["hermes-core", "todo", "persona"]
    assert stat.S_IMODE(config.stat().st_mode) == 0o640
    assert (config.stat().st_uid, config.stat().st_gid) == (original_stat.st_uid, original_stat.st_gid)
    manifest = json.loads((snapshot / "manifest.json").read_text())
    assert manifest["preimage_sha256"] != manifest["postimage_sha256"]
    assert (snapshot / "config.yaml.preimage").read_bytes() == original
    invoke("--config", str(config), "--topology", str(TOPOLOGY), "--persona", "jen", "--check-only")
    invoke("--config", str(config), "--restore-from", str(snapshot))
    assert config.read_bytes() == original
    assert stat.S_IMODE(config.stat().st_mode) == 0o640

    # Restore is single-state/CAS-bound: it refuses after any unrelated mutation.
    snapshot2 = temp / "snapshot2"
    invoke("--config", str(config), "--topology", str(TOPOLOGY), "--persona", "jen", "--snapshot-dir", str(snapshot2))
    config.write_text("unrelated: mutation\n")
    refused = invoke("--config", str(config), "--restore-from", str(snapshot2), check=False)
    assert refused.returncode == 2
    assert "not the snapshot-bound postimage" in refused.stderr

with tempfile.TemporaryDirectory() as raw:
    # A failure after durable snapshot creation leaves the config byte-identical.
    temp = Path(raw)
    config = temp / "config.yaml"
    original = b"platform_toolsets: {}\n"
    config.write_bytes(original)
    snapshot = temp / "failed-snapshot"
    module = load_module()
    real_replace = module.replace_config
    real_fsync = module.fsync_directory
    ordering = []
    def recording_fsync(path):
        ordering.append(("fsync", Path(path).resolve()))
        return real_fsync(path)
    def failed_replace(*_args, **_kwargs):
        ordering.append(("replace", config.resolve()))
        raise RuntimeError("injected replace failure")
    module.fsync_directory = recording_fsync
    module.replace_config = failed_replace
    try:
        try:
            module.materialize_config(config, TOPOLOGY, "jen", snapshot)
        except RuntimeError as exc:
            assert str(exc) == "injected replace failure"
        else:
            raise AssertionError("injected replacement failure was not raised")
    finally:
        module.replace_config = real_replace
        module.fsync_directory = real_fsync
    assert config.read_bytes() == original
    assert (snapshot / "manifest.json").is_file()
    assert (snapshot / "config.yaml.preimage").read_bytes() == original
    parent_fsync = ordering.index(("fsync", temp.resolve()))
    replace_attempt = ordering.index(("replace", config.resolve()))
    assert parent_fsync < replace_attempt

with tempfile.TemporaryDirectory() as raw:
    temp = Path(raw)
    topology = json.loads(TOPOLOGY.read_text())
    for persona, spec in topology["personas"].items():
        config = temp / f"{persona}.yaml"
        config.write_text(yaml.safe_dump({"platform_toolsets": {}}, sort_keys=False))
        snapshot = temp / f"{persona}.snapshot"
        invoke("--config", str(config), "--topology", str(TOPOLOGY), "--persona", persona, "--snapshot-dir", str(snapshot))
        data = yaml.safe_load(config.read_text())
        assert data["persona_api"]["self_target"] == persona
        assert set(data["persona_api"]["inbound"]["callers"]) == set(spec["inbound_callers"])
        assert set(data["persona_api"]["outbound"]["targets"]) == set(spec["outbound_targets"])
        for target, target_spec in data["persona_api"]["outbound"]["targets"].items():
            assert target_spec == {"url": f"http://{target}:{PORTS[target]}"}
        for platform in topology["session_platforms"]:
            assert data["platform_toolsets"][platform] == ["hermes-core", "persona"]
        assert "token_env" not in config.read_text()
        invoke("--config", str(config), "--restore-from", str(snapshot))

    for persona, spec in topology["personas"].items():
        for caller, token_env in spec["inbound_callers"].items():
            assert persona in topology["personas"][caller]["outbound_targets"]
            reverse = topology["personas"][caller]["outbound_targets"][persona]
            assert reverse["token_env"] == token_env
            assert reverse["url"] == f"http://{persona}:{PORTS[persona]}"

    bad_config = temp / "bad.yaml"
    bad_config.write_text("platform_toolsets: {}\n")
    bad = invoke("--config", str(bad_config), "--topology", str(TOPOLOGY), "--persona", "unknown", "--snapshot-dir", str(temp / "bad.snapshot"), check=False)
    assert bad.returncode == 2
    link = temp / "link.yaml"
    link.symlink_to(bad_config)
    symlink = invoke("--config", str(link), "--topology", str(TOPOLOGY), "--persona", "jen", "--snapshot-dir", str(temp / "link.snapshot"), check=False)
    assert symlink.returncode == 2

print("persona_api_materializer_ok")
