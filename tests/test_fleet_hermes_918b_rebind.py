import json
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / "ops/manifests/fleet-hermes-918b-rebind.lock.json"
VALIDATOR = ROOT / "ops/release/fleet_hermes_918b_rebind.py"

class FleetHermes918bRebindContractTests(unittest.TestCase):
    def run_validator(self, *extra):
        return subprocess.run([sys.executable, str(VALIDATOR), "--lock", str(LOCK), *extra], text=True, capture_output=True)

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

    def test_persona_builder_requires_tag_to_immutable_id_and_labels_tuple(self):
        builder = (ROOT / "ops/scripts/build-persona-base-candidate.sh").read_text()
        for required in ("HERMES_BASE_REBIND_LOCK", "fleet_hermes_918b_rebind.py", "--require-local-image-id", "docker image inspect \"$BASE_TAG\"", "[[ \"$ACTUAL_ID\" == \"$EXPECTED_ID\" ]]", "the-ai-crowd.hermes-base-tag=$BASE_TAG", "the-ai-crowd.hermes-base-id=$EXPECTED_ID", "the-ai-crowd.hermes-source-commit=$HERMES_REV", "the-ai-crowd.hermes-source-tree=$HERMES_TREE", "the-ai-crowd.hermes-source-archive-sha256=$HERMES_ARCHIVE_SHA256"):
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
