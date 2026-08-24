import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "ops/release/hermes_base_v4.py"
LOCK_PATH = ROOT / "ops/manifests/hermes-base-v4.lock.json"
BUILDER_PATH = ROOT / "ops/scripts/build-hermes-base-v4.sh"
spec = importlib.util.spec_from_file_location("hermes_base_v4", MODULE_PATH)
module = importlib.util.module_from_spec(spec)
assert spec and spec.loader
sys.modules[spec.name] = module
spec.loader.exec_module(module)


class HermesBaseV4ContractTests(unittest.TestCase):
    def lock(self):
        return json.loads(LOCK_PATH.read_text(encoding="utf-8"))

    def validator(self, payload, require_resolved=False):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "lock.json"
            path.write_text(json.dumps(payload), encoding="utf-8")
            command = [sys.executable, "-B", str(MODULE_PATH), "--lock", str(path), "--check-only"]
            if require_resolved:
                command.append("--require-resolved")
            return subprocess.run(command, text=True, capture_output=True, check=False)

    def test_exact_source_only_lock_is_valid_but_not_consumable(self):
        result = self.validator(self.lock())
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        blocked = self.validator(self.lock(), require_resolved=True)
        self.assertNotEqual(blocked.returncode, 0)
        self.assertIn("hermes_base_v4_build_receipt_required", blocked.stdout)

    def test_oci_index_cannot_be_consumed_as_platform_manifest_or_config(self):
        for field in ("platform_manifest_digest", "config_digest", "local_image_id"):
            with self.subTest(field=field):
                mutant = self.lock()
                mutant["resolved_build_identity"][field] = mutant["oci_index_digest"]
                result = self.validator(mutant)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"hermes_base_v4_unresolved_field_must_be_null: {field}", result.stdout)

    def test_null_identity_fields_cannot_be_silently_consumed(self):
        with self.assertRaisesRegex(module.ContractError, "platform_manifest_digest,config_digest,local_image_id"):
            module.require_resolved_build_receipt(self.lock())

    def test_validator_rejects_unknown_authority_bearing_fields(self):
        for section, field in ((None, "top_level_authority"), ("source", "source_authority"), ("build_gate", "build_authority")):
            with self.subTest(field=field):
                mutant = self.lock()
                if section == "build_gate":
                    mutant[section] = {"receipt_requirement": mutant[section], field: "unapproved"}
                else:
                    target = mutant if section is None else mutant[section]
                    target[field] = "unapproved"
                result = self.validator(mutant)
                self.assertNotEqual(result.returncode, 0)
                expected = f"hermes_base_v4_unknown_authority_key: {field}"
                self.assertEqual(expected, result.stdout.strip())

    def test_builder_rejects_arbitrary_archived_dockerfile_before_buildx(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "docker-called"
            fake_docker = Path(directory) / "docker"
            fake_docker.write_text("#!/bin/sh\ntouch \"$HERMES_BASE_V4_DOCKER_MARKER\"\n", encoding="utf-8")
            fake_docker.chmod(0o755)
            result = subprocess.run(
                [str(BUILDER_PATH), "--execute-build", "--agent-source", directory, "--file", "archive/Dockerfile", "--archive", f"{directory}/image.oci", "--receipt", f"{directory}/receipt.json"],
                text=True,
                capture_output=True,
                check=False,
                env={**os.environ, "PATH": f"{directory}:{os.environ['PATH']}", "HERMES_BASE_V4_DOCKER_MARKER": str(marker)},
            )
            self.assertFalse(marker.exists())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unapproved Dockerfile path: archive/Dockerfile", result.stderr)

    def test_builder_accepts_approved_dockerfile_path_before_later_gates(self):
        with tempfile.TemporaryDirectory() as directory:
            fake_git = Path(directory) / "git"
            fake_git.write_text("#!/bin/sh\nfor arg in \"$@\"; do [ \"$arg\" = status ] && exit 0; done\nexec /usr/bin/git \"$@\"\n", encoding="utf-8")
            fake_git.chmod(0o755)
            result = subprocess.run(
                [str(BUILDER_PATH), "--execute-build", "--agent-source", f"{directory}/missing-agent-source", "--file", "Dockerfile", "--archive", f"{directory}/image.oci", "--receipt", f"{directory}/receipt.json"],
                text=True,
                capture_output=True,
                check=False,
                env={**os.environ, "PATH": "{}:{}".format(directory, os.environ["PATH"])},
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Agent source checkout is required", result.stderr)

    def test_no_execute_preserves_no_implicit_build_semantics(self):
        result = subprocess.run([str(BUILDER_PATH), "--file", "Dockerfile"], text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("source-only plan valid; refusing to build without --execute-build", result.stderr)


if __name__ == "__main__":
    unittest.main()
