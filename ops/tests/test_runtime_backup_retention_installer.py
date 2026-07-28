from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

INSTALLER = Path(__file__).parents[1] / "install-runtime-backup-retention.sh"


class InstallerTests(unittest.TestCase):
    def fixture(self, root: Path):
        stack=root/"stack"; ops=stack/"ops"; ops.mkdir(parents=True)
        wrapper=ops/"runtime-backup-retention-wrapper.sh"; wrapper.write_text("#!/bin/sh\nexit 0\n"); wrapper.chmod(0o755)
        user=root/"user.scripts"; (user/"scripts").mkdir(parents=True)
        runtime=root/"runtime/schedule.json"; runtime.parent.mkdir()
        daily=root/"daily"; daily.write_text("#!/bin/sh\nexit 0\n"); daily.chmod(0o755)
        update=root/"update_cron"; update.write_text("#!/bin/sh\nexit 0\n"); update.chmod(0o755)
        env=os.environ|{"STACK_ROOT":str(stack),"USER_SCRIPTS_ROOT":str(user),"RUNTIME_SCHEDULE":str(runtime),"DAILY_RUNNER":str(daily),"UPDATE_CRON":str(update)}
        return stack,user,runtime,env

    def run_install(self, preimage: Path, env: dict[str,str], **extra):
        preimage.mkdir()
        return subprocess.run([str(INSTALLER),str(preimage)],env=env|extra,text=True,capture_output=True)

    def test_install_preserves_unrelated_schedule_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td); _,user,runtime,env=self.fixture(root)
            schedule=user/"schedule.json"; schedule.write_text(json.dumps({"/other/script":{"script":"/other/script","frequency":"weekly","id":"other","custom":""}}))
            first=self.run_install(root/"pre1",env); self.assertEqual(first.returncode,0,first.stderr)
            data=json.loads(schedule.read_text()); self.assertIn("/other/script",data)
            key=str(user/"scripts/runtime_backup_retention/script"); self.assertEqual(data[key]["frequency"],"daily")
            self.assertEqual(schedule.read_bytes(),runtime.read_bytes())
            second=self.run_install(root/"pre2",env); self.assertEqual(second.returncode,0,second.stderr)
            self.assertEqual(schedule.read_bytes(),runtime.read_bytes())

    def test_post_mutation_failure_restores_conflicting_preimages(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td); _,user,runtime,env=self.fixture(root)
            dest=user/"scripts/runtime_backup_retention"; dest.mkdir(); script=dest/"script"; name=dest/"name"
            script.write_bytes(b"old-script"); script.chmod(0o700); name.write_bytes(b"old-name")
            schedule=user/"schedule.json"; schedule.write_bytes(b'{"old":true}\n'); runtime.write_bytes(b'{"runtime":true}\n')
            before={p:(p.read_bytes(),p.stat().st_mode&0o777) for p in (script,name,schedule,runtime)}
            cp=self.run_install(root/"pre",env,ALLOW_TEST_FAILPOINT="1",INSTALL_FAILPOINT="after_schedule")
            self.assertNotEqual(cp.returncode,0); self.assertIn("SCHEDULER_RESTORED_AFTER_FAILURE",cp.stderr)
            for path,(data,mode) in before.items():
                self.assertEqual(path.read_bytes(),data); self.assertEqual(path.stat().st_mode&0o777,mode)

    def test_symlink_destination_rejected_without_mutation(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td); _,user,_,env=self.fixture(root)
            outside=root/"outside"; outside.write_text("safe")
            schedule=user/"schedule.json"; schedule.symlink_to(outside)
            cp=self.run_install(root/"pre",env)
            self.assertNotEqual(cp.returncode,0); self.assertEqual(outside.read_text(),"safe")

    def test_symlinked_scripts_ancestor_and_preimage_child_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td); _,user,_,env=self.fixture(root)
            scripts=user/"scripts"; scripts.rmdir(); outside=root/"outside"; outside.mkdir(); scripts.symlink_to(outside,target_is_directory=True)
            cp=self.run_install(root/"pre1",env); self.assertNotEqual(cp.returncode,0); self.assertEqual(list(outside.iterdir()),[])
            scripts.unlink(); scripts.mkdir()
            pre=root/"pre2"; pre.mkdir(); (pre/"scheduler").symlink_to(outside,target_is_directory=True)
            cp=subprocess.run([str(INSTALLER),str(pre)],env=env,text=True,capture_output=True)
            self.assertNotEqual(cp.returncode,0); self.assertEqual(list(outside.iterdir()),[])

    def test_update_cron_partial_failure_restores_observed_cron_state(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td); _,user,runtime,env=self.fixture(root)
            dest=user/"scripts/runtime_backup_retention"; dest.mkdir(); (dest/"script").write_text("old-script"); (dest/"name").write_text("old-name")
            schedule=user/"schedule.json"; old_schedule=b'{"old":true}\n'; schedule.write_bytes(old_schedule); runtime.write_bytes(b'{"runtime":true}\n')
            cron_state=root/"cron-state"; fail_once=root/"fail-once"; fail_once.write_text("1")
            update=root/"update-stateful"; update.write_text('#!/bin/sh\ncp "$SCHEDULE_PATH" "$CRON_STATE"\nif [ -f "$FAIL_ONCE" ]; then rm -f "$FAIL_ONCE"; exit 1; fi\n'); update.chmod(0o755)
            env=env|{"UPDATE_CRON":str(update),"SCHEDULE_PATH":str(schedule),"CRON_STATE":str(cron_state),"FAIL_ONCE":str(fail_once)}
            cp=self.run_install(root/"pre",env)
            self.assertNotEqual(cp.returncode,0); self.assertIn("SCHEDULER_RESTORED_AFTER_FAILURE",cp.stderr)
            self.assertEqual(schedule.read_bytes(),old_schedule); self.assertEqual(cron_state.read_bytes(),old_schedule)


if __name__ == "__main__": unittest.main()
