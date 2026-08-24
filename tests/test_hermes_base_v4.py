import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "ops/release/hermes_base_v4.py"
LOCK_PATH = ROOT / "ops/manifests/hermes-base-v4.lock.json"
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


if __name__ == "__main__":
    unittest.main()
