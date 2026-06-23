import importlib.util
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


class RouteMatrixTests(unittest.TestCase):
    def test_matrix_covers_all_personas_and_domains(self):
        module = load_module()
        matrix = module.route_matrix()
        self.assertEqual(set(matrix), set(module.PERSONAS))
        for persona in module.PERSONAS:
            self.assertEqual(set(matrix[persona]), set(module.OWNER_DOMAINS))

    def test_technical_failures_route_to_moss_and_keep_source_owner(self):
        module = load_module()
        for persona in module.PERSONAS:
            route = module.resolve_route(
                source_persona=persona,
                owner_domain="technical-ops",
                handoff_type="incident",
                failure_class="auth_failure",
            )
            self.assertEqual(route["target_persona"], "moss")
            self.assertEqual(route["executor"], "moss")
            self.assertEqual(route["decision_owner"], persona)
            self.assertEqual(route["reason"], "technical_failure")

    def test_domain_routes_use_domain_owner(self):
        module = load_module()
        expectations = {
            "product": "denholm",
            "productivity": "jen",
            "intake": "roy",
            "archiveops": "richmond",
            "prepared-answer": "the-elders",
        }
        for owner_domain, owner in expectations.items():
            route = module.resolve_route(
                source_persona="moss",
                owner_domain=owner_domain,
                handoff_type="consultation",
            )
            self.assertEqual(route["target_persona"], owner)
            self.assertEqual(route["decision_owner"], owner)
            self.assertEqual(route["matrix_owner"], owner)

    def test_explicit_target_override_keeps_domain_owner(self):
        module = load_module()
        route = module.resolve_route(
            source_persona="denholm",
            owner_domain="product",
            handoff_type="execution_request",
            target_persona="moss",
        )
        self.assertEqual(route["target_persona"], "moss")
        self.assertEqual(route["decision_owner"], "denholm")
        self.assertEqual(route["matrix_owner"], "denholm")
        self.assertEqual(route["reason"], "explicit_target")


if __name__ == "__main__":
    unittest.main()
