from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

SCRIPT = Path(__file__).parents[1] / "runtime-backup-retention.py"


def payload(path: Path, data: bytes) -> dict[str, object]:
    path.write_bytes(data)
    return {"path": path.name, "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}


class RetentionTests(unittest.TestCase):
    def run_script(self, root: Path, now: int = 1000, dry: bool = False):
        cmd = ["python3", str(SCRIPT), "--root", str(root), "--now", str(now)]
        if dry:
            cmd.append("--dry-run")
        return subprocess.run(cmd, text=True, capture_output=True)

    def make_set(self, root: Path, name: str, *, state="activated", expires=900, retained=False, corrupt=False):
        op = root / name; op.mkdir()
        entry = payload(op / "preimage.tar", b"preimage")
        if corrupt:
            (op / "preimage.tar").write_bytes(b"drift")
        (op / "manifest.json").write_text(json.dumps({"schema_version":1,"operation_id":name,"state":state,"expires_at":expires,"retained":retained,"payloads":[entry]}))
        return op

    def test_expired_terminal_deleted_but_nonterminal_preserved(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td); expired=self.make_set(root,"expired"); active=self.make_set(root,"active",state="active")
            cp=self.run_script(root)
            self.assertEqual(cp.returncode,0,cp.stderr); self.assertFalse(expired.exists()); self.assertTrue(active.exists())

    def test_unexpired_retained_corrupt_and_extra_fail_closed(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td)
            unexpired=self.make_set(root,"unexpired",expires=2000)
            retained=self.make_set(root,"retained",retained=True)
            corrupt=self.make_set(root,"corrupt",corrupt=True)
            extra=self.make_set(root,"extra"); (extra/"unknown").write_text("x")
            cp=self.run_script(root)
            self.assertEqual(cp.returncode,0,cp.stderr)
            for path in (unexpired,retained,corrupt,extra): self.assertTrue(path.exists())
            result=json.loads(cp.stdout); self.assertEqual(len(result["rejected"]),2)

    def test_symlink_operation_and_missing_root_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td); outside=root/"outside"; outside.mkdir(); (root/"linked").symlink_to(outside, target_is_directory=True)
            cp=self.run_script(root); self.assertEqual(cp.returncode,0); self.assertTrue(outside.exists())
            missing=self.run_script(root/"missing"); self.assertNotEqual(missing.returncode,0); self.assertFalse((root/"missing").exists())

    def test_dry_run_is_non_mutating(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td); op=self.make_set(root,"expired")
            cp=self.run_script(root,dry=True); self.assertEqual(cp.returncode,0); self.assertTrue(op.exists())

    def test_duplicate_payload_name_rejected_before_any_unlink(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td); op=self.make_set(root,"duplicate")
            manifest=json.loads((op/"manifest.json").read_text()); manifest["payloads"].append(dict(manifest["payloads"][0]))
            (op/"manifest.json").write_text(json.dumps(manifest))
            cp=self.run_script(root); self.assertEqual(cp.returncode,0,cp.stderr)
            self.assertTrue((op/"preimage.tar").exists()); self.assertIn("duplicate_payload_name",cp.stdout)

    def test_operation_replacement_after_open_is_not_deleted(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td); original=self.make_set(root,"expired"); race=root/"race"; race.mkdir()
            env=os.environ|{"ALLOW_TEST_RACE_HOOK":"1","RETENTION_TEST_RACE_DIR":str(race)}
            proc=subprocess.Popen(["python3",str(SCRIPT),"--root",str(root),"--now","1000"],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            marker=race/"expired.opened"
            for _ in range(500):
                if marker.exists(): break
                if proc.poll() is not None: break
                time.sleep(0.01)
            self.assertTrue(marker.exists())
            held=root/"held"; original.rename(held); replacement=root/"expired"; replacement.mkdir(); (replacement/"sentinel").write_text("safe")
            (race/"continue").write_text("1"); stdout,stderr=proc.communicate(timeout=10)
            self.assertEqual(proc.returncode,0,stderr); self.assertTrue((replacement/"sentinel").exists()); self.assertTrue((held/"preimage.tar").exists())
            self.assertIn("operation_identity_changed",stdout)


if __name__ == "__main__": unittest.main()
