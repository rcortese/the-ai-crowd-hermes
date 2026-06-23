import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LIB_PATH = ROOT / "shared/protocol/lib/the_ai_crowd_handoff.py"


def load_module():
    spec = importlib.util.spec_from_file_location("the_ai_crowd_handoff", LIB_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class RootDriftTests(unittest.TestCase):
    def test_rejects_drifted_kanban_root(self):
        module = load_module()
        with self.assertRaises(module.ValidationError):
            module.validate_root("/mnt/hermes-shared/kanban/the-ai-crowd")

    def test_rejects_conceptual_repo_protocol_root(self):
        module = load_module()
        with self.assertRaises(module.ValidationError):
            module.validate_root("/workspace/the-ai-crowd/protocol")

    def test_rejects_non_absolute_root(self):
        module = load_module()
        with self.assertRaises(module.ValidationError):
            module.validate_root("handoffs")

    def test_allows_tmp_root_only_when_enabled(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as tmpdir:
            with self.assertRaises(module.ValidationError):
                module.validate_root(tmpdir)
            resolved = module.validate_root(tmpdir, allow_test_root=True)
            self.assertEqual(resolved, Path(tmpdir).resolve())


if __name__ == "__main__":
    unittest.main()
