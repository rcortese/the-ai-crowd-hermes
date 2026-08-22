import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / "ops/manifests/fleet-hermes-918b-rebind.lock.json"
V3_LOCK = ROOT / "ops/manifests/hermes-base-v3.lock.json"
VALIDATOR = ROOT / "ops/release/fleet_hermes_918b_rebind.py"
IMAGE_ID = "sha256:" + "a" * 64


class FleetHermes918bRebindContractTests(unittest.TestCase):
    def run_validator(self, *extra):
        return subprocess.run([sys.executable, str(VALIDATOR), "--lock", str(LOCK), *extra], text=True, capture_output=True)

    def admitted_artifacts(self):
        tmp = tempfile.TemporaryDirectory()
        directory = Path(tmp.name)
        fleet = json.loads(LOCK.read_text())
        fleet["base"]["local_image_id"] = IMAGE_ID
        fleet_path = directory / "fleet.json"
        fleet_path.write_text(json.dumps(fleet))
        v3_path = directory / "v3.json"
        shutil.copyfile(V3_LOCK, v3_path)
        v3 = json.loads(v3_path.read_text())
        source, image = v3["source"], v3["image"]
        normalized = {"Env": ["fixture=true"]}
        receipt = {
            "schema": "the-ai-crowd.hermes-base-v3-receipt.v1",
            "source_commit": source["commit"],
            "source_tree": source["tree"],
            "archive_sha256": source["archive"]["sha256"],
            "archive_bytes": source["archive"]["bytes"],
            "pre_normalization_tag": image["pre_normalization_tag"],
            "pre_normalization_image_id": "sha256:" + "b" * 64,
            "final_tag": image["final_tag"],
            "final_image_id": IMAGE_ID,
            "normalized_config": normalized,
            "normalized_config_sha256": hashlib.sha256(json.dumps(normalized, sort_keys=True, separators=(",", ":")).encode()).hexdigest(),
        }
        receipt_path = directory / "receipt.json"
        receipt_path.write_text(json.dumps(receipt))
        inspect = directory / "inspect"
        inspect.write_text("#!/usr/bin/env python3\nimport os\nprint(os.environ['FIXTURE_IMAGE_ID'])\n")
        inspect.chmod(0o755)
        return tmp, fleet_path, v3_path, receipt_path, inspect

    def run_admit(self, fleet, v3, receipt, inspect, image_id=IMAGE_ID):
        return subprocess.run(
            [sys.executable, str(VALIDATOR), "admit", "--lock", str(fleet), "--v3-lock", str(v3), "--receipt", str(receipt), "--inspect-command", str(inspect)],
            text=True, capture_output=True, env={**os.environ, "FIXTURE_IMAGE_ID": image_id},
        )

    def test_lock_binds_v3_tag_local_id_slot_and_source_tuple(self):
        lock = json.loads(LOCK.read_text())
        self.assertEqual(lock["status"], "source-only-quarantined")
        self.assertEqual(lock["base"]["tag"], "the-ai-crowd/hermes-base:918b36785653")
        self.assertIsNone(lock["base"]["local_image_id"])
        self.assertEqual(lock["base"]["source"]["commit"], "918b36785653ec291806558e30b302b8cad10777")
        self.assertEqual(self.run_validator().returncode, 0)

    def test_unbound_local_image_id_fails_closed(self):
        result = self.run_validator("--require-local-image-id")
        self.assertEqual(result.returncode, 65)
        self.assertIn("local image ID is unbound", result.stderr)

    def test_admission_rejects_arbitrary_id_missing_receipt_tuple_mismatch_and_tag_drift_before_build(self):
        tmp, fleet, v3, receipt, inspect = self.admitted_artifacts()
        self.addCleanup(tmp.cleanup)
        self.assertEqual(self.run_admit(fleet, v3, receipt, inspect).returncode, 0)
        self.assertEqual(self.run_admit(fleet, v3, receipt, inspect, "sha256:" + "c" * 64).returncode, 65)
        self.assertEqual(self.run_admit(fleet, v3, receipt.with_name("missing.json"), inspect).returncode, 65)
        bad = json.loads(receipt.read_text())
        bad["source_tree"] = "d" * 40
        receipt.write_text(json.dumps(bad))
        self.assertEqual(self.run_admit(fleet, v3, receipt, inspect).returncode, 65)
        bad["source_tree"] = json.loads(v3.read_text())["source"]["tree"]
        bad["final_tag"] = "the-ai-crowd/hermes-base:drift"
        receipt.write_text(json.dumps(bad))
        self.assertEqual(self.run_admit(fleet, v3, receipt, inspect).returncode, 65)

    def test_persona_builder_requires_tag_to_immutable_id_and_labels_tuple(self):
        builder = (ROOT / "ops/scripts/build-persona-base-candidate.sh").read_text()
        for required in ("HERMES_BASE_REBIND_LOCK", "HERMES_BASE_V3_RECEIPT", "fleet_hermes_918b_rebind.py\" admit", "--v3-lock", "--receipt", "--inspect-command docker", "docker image inspect \"$BASE_TAG\"", "[[ \"$ACTUAL_ID\" == \"$EXPECTED_ID\" ]]", "the-ai-crowd.hermes-base-tag=$BASE_TAG", "the-ai-crowd.hermes-base-id=$EXPECTED_ID", "the-ai-crowd.hermes-source-commit=$HERMES_REV", "the-ai-crowd.hermes-source-tree=$HERMES_TREE", "the-ai-crowd.hermes-source-archive-sha256=$HERMES_ARCHIVE_SHA256"):
            self.assertIn(required, builder)

    def test_image_pin_contract_covers_rebind_packet(self):
        image_pin = (ROOT / "tests/image-pin.sh").read_text()
        self.assertIn("fleet-hermes-918b-rebind.lock.json", image_pin)
        self.assertIn("fleet_hermes_918b_rebind.py", image_pin)

    def test_moss_all_in_one_and_a2a_overlay_are_not_full_base_rebinds(self):
        self.assertNotIn("fleet-hermes-918b-rebind", (ROOT / "ops/images/Dockerfile.moss-all-in-one").read_text())
        self.assertNotIn("fleet-hermes-918b-rebind", (ROOT / "ops/images/Dockerfile.moss-a2a-overlay").read_text())
        quarantine = ROOT / "ops/scripts/quarantine-a2a-overlay-full-base-rebind.sh"
        self.assertTrue(quarantine.stat().st_mode & 0o111)
        self.assertIn("quarantined", quarantine.read_text())


if __name__ == "__main__":
    unittest.main()
