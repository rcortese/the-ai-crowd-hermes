import json
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WATCH_SCRIPT = ROOT / "agents/public/jen/tools/cron-scripts/jen-calendar-auth-watch.sh"
HANDOFF_WRAPPER = ROOT / "agents/public/jen/bin/jen-handoff"


def write_executable(path: Path, content: str) -> None:
    path.write_text(content)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class JenCalendarAuthWatchTests(unittest.TestCase):
    def test_alert_mode_can_generate_canonical_handoff_preview(self):
        if shutil.which("bash") is None:
            self.skipTest("bash is required to execute the watcher contract")
        if shutil.which("jq") is None:
            self.skipTest("jq is required to execute the watcher contract")
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            state_dir = tmp / "state"
            handoff_root = tmp / "handoffs"
            runtime_wrapper = tmp / "jen-calendar-runtime"
            write_executable(
                runtime_wrapper,
                "#!/usr/bin/env bash\ncat <<'JSON'\n{\"status\":\"degraded\",\"live_read_status\":\"auth_failure\",\"posture\":\"reauth-required\"}\nJSON\n",
            )
            env = os.environ.copy()
            env.update(
                {
                    "JEN_CRON_STATE_DIR": str(state_dir),
                    "JEN_CALENDAR_RUNTIME_WRAPPER": str(runtime_wrapper),
                    "JEN_HANDOFF_WRAPPER": str(HANDOFF_WRAPPER),
                    "JEN_CALENDAR_AUTH_WATCH_HANDOFF_MODE": "dry-run",
                    "JEN_CALENDAR_AUTH_WATCH_HANDOFF_ROOT": str(handoff_root),
                    "JEN_CALENDAR_AUTH_WATCH_ALLOW_TEST_ROOT": "1",
                }
            )
            result = subprocess.run(["bash", str(WATCH_SCRIPT)], capture_output=True, text=True, env=env, check=True)
            self.assertIn("canonical_handoff_mode=dry-run", result.stdout)
            state = json.loads((state_dir / "calendar-auth-watch.json").read_text())
            self.assertTrue(state["alert_required"])
            self.assertEqual(state["canonical_handoff_mode"], "dry-run")
            self.assertEqual(state["canonical_handoff"]["target"]["persona"], "moss")
            self.assertEqual(state["canonical_handoff_failure_class"], "auth_failure")
            self.assertEqual(state["canonical_handoff"]["route"]["canonical_root"], str(handoff_root.resolve()))
            self.assertFalse(Path(state["canonical_handoff"]["target"]["path"]).exists())


if __name__ == "__main__":
    unittest.main()
