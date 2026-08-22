import hashlib
import io
import pathlib
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "ops" / "release"))
import hermes_base_v3 as contract

COMMIT = "918b36785653ec291806558e30b302b8cad10777"
TREE = "817966c265522f8a7ae07473284451e17f1e683a"
ARCHIVE_SHA = "8a26e82ce96b4b5429d0321e19ddb0b01bed9d5925ab2a0ecc89e9201bfe6aee"

def lock_data():
    return {
        "schema": contract.LOCK_SCHEMA,
        "source": {"git_dir": "/declared/git-dir", "work_tree": "/declared/work-tree", "commit": COMMIT, "tree": TREE, "archive": {"format": "tar", "prefix": "hermes-agent/", "sha256": ARCHIVE_SHA, "bytes": 166256640}},
        "image": {"repository": "the-ai-crowd/hermes-base", "pre_normalization_tag": "candidate", "final_tag": None, "final_image_id": None},
        "receipt": None,
    }

class LockValidationTests(unittest.TestCase):
    def test_valid_source_only_lock_is_accepted(self):
        self.assertEqual(contract.validate_lock(lock_data())["source"]["commit"], COMMIT)

    def test_lock_rejects_unknown_and_wrong_typed_fields(self):
        candidate = lock_data(); candidate["unexpected"] = True
        with self.assertRaisesRegex(ValueError, "unexpected"):
            contract.validate_lock(candidate)
        candidate = lock_data(); candidate["source"]["archive"]["bytes"] = "166256640"
        with self.assertRaisesRegex(ValueError, "bytes"):
            contract.validate_lock(candidate)

    def test_archive_binding_checks_exact_bytes_and_digest(self):
        archive = b"archive-fixture"
        candidate = lock_data(); candidate["source"]["archive"] = {"format": "tar", "prefix": "hermes-agent/", "sha256": hashlib.sha256(archive).hexdigest(), "bytes": len(archive)}
        contract.verify_archive_stream(candidate, io.BytesIO(archive))
        with self.assertRaisesRegex(ValueError, "sha256"):
            contract.verify_archive_stream(candidate, io.BytesIO(b"archive-fixturE"))

class NormalizationTests(unittest.TestCase):
    def test_normalization_removes_only_opt_data_volume(self):
        original = {"Config": {"Volumes": {"/opt/data": {}, "/tmp": {"mode": "rw"}}, "Env": ["A=B"]}, "RootFS": {"Type": "layers"}}
        normalized = contract.normalize_oci_config(original)
        self.assertEqual(normalized["Config"]["Volumes"], {"/tmp": {"mode": "rw"}})
        self.assertEqual(normalized["Config"]["Env"], ["A=B"])
        self.assertEqual(original["Config"]["Volumes"], {"/opt/data": {}, "/tmp": {"mode": "rw"}})

    def test_normalization_preserves_empty_volume_mapping(self):
        self.assertEqual(contract.normalize_oci_config({"Config": {"Volumes": {"/opt/data": {}}}}), {"Config": {"Volumes": {}}})

class ReceiptTests(unittest.TestCase):
    def test_receipt_requires_final_custody_values_and_bound_source(self):
        receipt = {"schema": contract.RECEIPT_SCHEMA, "source_commit": COMMIT, "source_tree": TREE, "archive_sha256": ARCHIVE_SHA, "archive_bytes": 166256640, "pre_normalization_tag": "the-ai-crowd/hermes-base:pre", "pre_normalization_image_id": "sha256:" + "a" * 64, "final_tag": "the-ai-crowd/hermes-base:final", "final_image_id": "sha256:" + "b" * 64, "normalized_config_sha256": "c" * 64}
        self.assertEqual(contract.verify_receipt(receipt, lock_data())["final_tag"], receipt["final_tag"])
        receipt["final_image_id"] = None
        with self.assertRaisesRegex(ValueError, "final_image_id"):
            contract.verify_receipt(receipt, lock_data())

if __name__ == "__main__":
    unittest.main()
