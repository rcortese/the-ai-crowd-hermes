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


def write_executable(path: Path, content: str) -> None:
    path.write_text(content)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class JenCalendarAuthWatchTests(unittest.TestCase):
    def test_degradation_stays_local_and_records_alert_without_handoff(self):
        if shutil.which("bash") is None:
            self.skipTest("bash is required to execute the watcher contract")
        if shutil.which("jq") is None:
            self.skipTest("jq is required to execute the watcher contract")
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            state_dir = tmp / "state"
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
                }
            )
            result = subprocess.run(["bash", str(WATCH_SCRIPT)], capture_output=True, text=True, env=env, check=True)
            self.assertIn("Jen Calendar: runtime degradado", result.stdout)
            state = json.loads((state_dir / "calendar-auth-watch.json").read_text())
            self.assertEqual(state["contract_version"], "jen-calendar-auth-watch.v2")
            self.assertTrue(state["alert_required"])
            self.assertEqual(state["live_read_status"], "auth_failure")
            self.assertFalse(any("handoff" in key for key in state))


if __name__ == "__main__":
    unittest.main()
