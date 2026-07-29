from __future__ import annotations

import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).parents[1]
WRAPPER = ROOT / "runtime-backup-retention-wrapper.sh"
SWEEPER = ROOT / "runtime-backup-retention.py"
IMAGE = "sha256:dace20db1109a3c2ea1da43b5d2fb68d6740ed6cbc15946cd7683d951b4d0e44"


class WrapperTests(unittest.TestCase):
    def fixture(self, td: str):
        root=Path(td); stack=root/"stack"; ops=stack/"ops"; backup=stack/"state/private/backups/runtime-preimages"
        ops.mkdir(parents=True); backup.mkdir(parents=True); (ops/"runtime-backup-retention.py").write_bytes(SWEEPER.read_bytes())
        bin_dir=root/"bin"; bin_dir.mkdir(); record=root/"record"
        docker=bin_dir/"docker"
        docker.write_text("""#!/bin/bash
set -euo pipefail
if [[ "$1" == image && "$2" == inspect ]]; then printf '%s\n' "$EXPECTED_IMAGE"; exit 0; fi
printf '%s\n' "$@" > "$DOCKER_RECORD"
for arg in "$@"; do
  if [[ "$arg" == type=bind,src=/tmp/runtime-backup-retention.*.py,dst=/opt/runtime-backup-retention.py,readonly ]]; then
    src=${arg#type=bind,src=}; src=${src%,dst=*}; sha256sum "$src" | cut -d' ' -f1 > "$DOCKER_RECORD.sha"; exit 0
  fi
done
exit 9
"""); docker.chmod(0o755)
        env=os.environ|{"STACK_ROOT":str(stack),"PATH":str(bin_dir)+":"+os.environ["PATH"],"EXPECTED_IMAGE":IMAGE,"DOCKER_RECORD":str(record)}
        return stack,record,env

    def test_exact_sweeper_snapshot_is_mounted(self):
        with tempfile.TemporaryDirectory() as td:
            _,record,env=self.fixture(td); cp=subprocess.run([str(WRAPPER)],env=env,text=True,capture_output=True)
            self.assertEqual(cp.returncode,0,cp.stderr)
            self.assertEqual(Path(str(record)+".sha").read_text().strip(),hashlib.sha256(SWEEPER.read_bytes()).hexdigest())

    def test_mutated_sweeper_is_rejected_before_docker_run(self):
        with tempfile.TemporaryDirectory() as td:
            stack,record,env=self.fixture(td); (stack/"ops/runtime-backup-retention.py").write_text("mutated")
            cp=subprocess.run([str(WRAPPER)],env=env,text=True,capture_output=True)
            self.assertNotEqual(cp.returncode,0); self.assertIn("sweeper_source_hash_mismatch",cp.stderr); self.assertFalse(record.exists())


if __name__ == "__main__": unittest.main()
