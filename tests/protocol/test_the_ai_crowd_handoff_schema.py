import importlib.util
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LIB_PATH = ROOT / "shared/protocol/lib/the_ai_crowd_handoff.py"
SCHEMA_PATH = ROOT / "schemas/the-ai-crowd-handoff.schema.json"
EXAMPLE_PATH = ROOT / "examples/handoffs/the-ai-crowd-handoff.example.json"
FIXTURE_DIR = ROOT / "tests/protocol/fixtures"


def load_module():
    spec = importlib.util.spec_from_file_location("the_ai_crowd_handoff", LIB_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class SchemaContractTests(unittest.TestCase):
    def test_schema_file_declares_required_keys(self):
        schema = json.loads(SCHEMA_PATH.read_text())
        self.assertEqual(schema["$schema"], "https://json-schema.org/draft/2020-12/schema")
        self.assertEqual(schema["type"], "object")
        for key in (
            "schema_version",
            "message_id",
            "correlation_id",
            "idempotency_key",
            "created_at",
            "source",
            "target",
            "owner_domain",
            "handoff_type",
            "decision_owner",
            "executor",
            "return_to",
            "privacy_class",
            "summary",
            "objective",
            "context",
            "artifact_refs",
            "route",
            "receipt",
            "adapter",
        ):
            self.assertIn(key, schema["required"])

    def test_valid_fixture_passes_validator(self):
        module = load_module()
        payload = json.loads((FIXTURE_DIR / "the-ai-crowd-handoff.valid.json").read_text())
        validated = module.validate_envelope(payload)
        self.assertEqual(validated["message_id"], payload["message_id"])

    def test_invalid_fixture_fails_validator(self):
        module = load_module()
        payload = json.loads((FIXTURE_DIR / "the-ai-crowd-handoff.invalid-missing-summary.json").read_text())
        with self.assertRaises(module.ValidationError):
            module.validate_envelope(payload)

    def test_example_file_validates(self):
        module = load_module()
        payload = json.loads(EXAMPLE_PATH.read_text())
        validated = module.validate_envelope(payload)
        self.assertEqual(validated["schema_version"], module.SCHEMA_VERSION)


if __name__ == "__main__":
    unittest.main()
