import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CLI_PATH = ROOT / "shared/protocol/bin/the-ai-crowd-handoff"
WRAPPER_DIRS = {
    "moss": ROOT / "agents/public/moss/bin/moss-handoff",
    "jen": ROOT / "agents/public/jen/bin/jen-handoff",
    "denholm": ROOT / "agents/public/denholm/bin/denholm-handoff",
    "roy": ROOT / "agents/public/roy/bin/roy-handoff",
    "richmond": ROOT / "agents/public/richmond/bin/richmond-handoff",
    "the-elders": ROOT / "agents/public/the-elders/bin/the-elders-handoff",
}
JEN_INCIDENT = ROOT / "agents/public/jen/bin/jen-open-moss-incident"


class WrapperContractTests(unittest.TestCase):
    def test_dry_run_prints_planned_path_without_writing(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            result = subprocess.run(
                [
                    "python3",
                    str(CLI_PATH),
                    "emit",
                    "--source",
                    "jen",
                    "--owner-domain",
                    "technical-ops",
                    "--handoff-type",
                    "incident",
                    "--failure-class",
                    "auth_failure",
                    "--summary",
                    "Calendar auth failure needs Moss triage.",
                    "--objective",
                    "Create a sanitized technical incident.",
                    "--context",
                    "No raw OAuth material included.",
                    "--idempotency-key",
                    "jen-calendar-auth:2026-06-21T20",
                    "--root",
                    tmpdir,
                    "--allow-test-root",
                    "--dry-run",
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            payload = json.loads(result.stdout)
            self.assertFalse(Path(payload["target"]["path"]).exists())
            self.assertEqual(payload["route"]["canonical_root"], str(Path(tmpdir).resolve()))

    def test_emit_writes_json_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            result = subprocess.run(
                [
                    "python3",
                    str(CLI_PATH),
                    "emit",
                    "--source",
                    "jen",
                    "--owner-domain",
                    "technical-ops",
                    "--handoff-type",
                    "incident",
                    "--failure-class",
                    "auth_failure",
                    "--summary",
                    "Calendar auth failure needs Moss triage.",
                    "--objective",
                    "Create a sanitized technical incident.",
                    "--context",
                    "No raw OAuth material included.",
                    "--idempotency-key",
                    "jen-calendar-auth:2026-06-21T20",
                    "--root",
                    tmpdir,
                    "--allow-test-root",
                    "--write",
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            payload = json.loads(result.stdout)
            emitted_path = Path(payload["target"]["path"])
            self.assertTrue(emitted_path.exists())
            written = json.loads(emitted_path.read_text())
            self.assertEqual(written["message_id"], payload["message_id"])

    def test_message_id_changes_between_emits(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            common = [
                "python3",
                str(CLI_PATH),
                "emit",
                "--source",
                "jen",
                "--owner-domain",
                "technical-ops",
                "--handoff-type",
                "incident",
                "--failure-class",
                "auth_failure",
                "--summary",
                "Calendar auth failure needs Moss triage.",
                "--objective",
                "Create a sanitized technical incident.",
                "--context",
                "No raw OAuth material included.",
                "--idempotency-key",
                "jen-calendar-auth:2026-06-21T20",
                "--root",
                tmpdir,
                "--allow-test-root",
                "--dry-run",
            ]
            first = json.loads(subprocess.run(common, check=True, capture_output=True, text=True).stdout)
            second = json.loads(subprocess.run(common, check=True, capture_output=True, text=True).stdout)
            self.assertNotEqual(first["message_id"], second["message_id"])
            self.assertEqual(first["idempotency_key"], second["idempotency_key"])

    def test_secret_like_text_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            result = subprocess.run(
                [
                    "python3",
                    str(CLI_PATH),
                    "emit",
                    "--source",
                    "jen",
                    "--owner-domain",
                    "technical-ops",
                    "--handoff-type",
                    "incident",
                    "--failure-class",
                    "auth_failure",
                    "--summary",
                    "Authorization: Bearer secret...ue",
                    "--objective",
                    "Create a sanitized technical incident.",
                    "--context",
                    "No raw OAuth material included.",
                    "--idempotency-key",
                    "jen-calendar-auth:2026-06-21T20",
                    "--root",
                    tmpdir,
                    "--allow-test-root",
                    "--dry-run",
                ],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("secret", (result.stderr + result.stdout).lower())

    def test_each_persona_wrapper_dry_run_matches_contract(self):
        for persona, wrapper_path in WRAPPER_DIRS.items():
            with self.subTest(persona=persona), tempfile.TemporaryDirectory() as tmpdir:
                result = subprocess.run(
                    [
                        "python3",
                        str(wrapper_path),
                        "emit",
                        "--target",
                        "moss",
                        "--owner-domain",
                        "technical-ops",
                        "--handoff-type",
                        "incident",
                        "--failure-class",
                        "auth_failure",
                        "--summary",
                        f"Synthetic {persona} technical handoff.",
                        "--objective",
                        "Create a sanitized technical incident.",
                        "--context",
                        "No raw OAuth material included.",
                        "--idempotency-key",
                        f"wrapper-smoke:{persona}",
                        "--root",
                        tmpdir,
                        "--allow-test-root",
                        "--dry-run",
                    ],
                    check=True,
                    capture_output=True,
                    text=True,
                )
                payload = json.loads(result.stdout)
                self.assertEqual(payload["source"]["persona"], persona)
                self.assertEqual(payload["source"]["wrapper"], f"{persona}-handoff")
                self.assertEqual(payload["target"]["persona"], "moss")
                self.assertEqual(payload["route"]["canonical_root"], str(Path(tmpdir).resolve()))
                self.assertFalse(Path(payload["target"]["path"]).exists())

    def test_wrapper_rejects_legacy_root(self):
        result = subprocess.run(
            [
                "python3",
                str(WRAPPER_DIRS["jen"]),
                "emit",
                "--target",
                "moss",
                "--owner-domain",
                "technical-ops",
                "--handoff-type",
                "incident",
                "--failure-class",
                "auth_failure",
                "--summary",
                "Reject the legacy root.",
                "--objective",
                "Prove root drift is rejected.",
                "--context",
                "No raw OAuth material included.",
                "--idempotency-key",
                "wrapper-root-drift",
                "--root",
                "/mnt/hermes-shared/kanban/the-ai-crowd",
                "--dry-run",
            ],
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("root_drift", result.stderr)

    def test_the_elders_wrapper_blocks_direct_emit(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            result = subprocess.run(
                [
                    "python3",
                    str(WRAPPER_DIRS["the-elders"]),
                    "emit",
                    "--target",
                    "moss",
                    "--owner-domain",
                    "technical-ops",
                    "--handoff-type",
                    "incident",
                    "--failure-class",
                    "runtime_failure",
                    "--summary",
                    "Synthetic elders technical handoff.",
                    "--objective",
                    "Prove direct emit stays runtime-blocked.",
                    "--context",
                    "No raw OAuth material included.",
                    "--idempotency-key",
                    "the-elders-runtime-block",
                    "--root",
                    tmpdir,
                    "--allow-test-root",
                    "--write",
                ],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("runtime-blocked", result.stderr)

    def test_jen_open_moss_incident_uses_canonical_handoff(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            result = subprocess.run(
                [
                    "python3",
                    str(JEN_INCIDENT),
                    "Calendar auth degraded",
                    "--severity",
                    "medium",
                    "--evidence",
                    "summary:calendar-health-json",
                    "--root",
                    tmpdir,
                    "--allow-test-root",
                    "--dry-run",
                ],
                input="No raw OAuth material included.",
                capture_output=True,
                text=True,
                check=True,
            )
            payload = json.loads(result.stdout)
            self.assertEqual(payload["source"]["persona"], "jen")
            self.assertEqual(payload["source"]["wrapper"], "jen-open-moss-incident")
            self.assertEqual(payload["target"]["persona"], "moss")
            self.assertEqual(payload["failure_class"], "runtime_failure")
            self.assertFalse(Path(payload["target"]["path"]).exists())


if __name__ == "__main__":
    unittest.main()
