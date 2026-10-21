"""Sandbox-only activation contract tests; Docker is always mocked.

Run: python3 -m unittest discover -s ops/scripts/tests -v
Expected failures document reproduced safety defects in the reviewed candidate;
remove each decorator when its production fix lands. No production paths are read.
"""
import contextlib
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import types
import unittest
from typing import Any
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "apply-paperclip-external-origin.py"


class ActivationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(
            prefix="activation-unit-", dir=os.environ["TMPDIR"]
        )
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.mod: Any = types.ModuleType("activation_under_test")
        exec(compile(SCRIPT.read_text(), str(SCRIPT), "exec"), self.mod.__dict__)
        self.mod.ROOT = self.root
        self.mod.STATE = self.root / "state"
        self.mod.CONFIG = self.root / "config.yaml"
        self.mod.KEY = self.root / "secrets" / "fixture.key"
        self.original_config = b"fixture:\n      PAPERCLIP_RUN_CONTEXT_MODE: request\n"
        self.mod.CONFIG.write_bytes(self.original_config)
        self.inputs = [self.root / "compose.json", self.root / "existing.json"]
        for path in self.inputs:
            path.write_text("{}")
        self.component = "moss"
        self.mutate_after = lambda model: None
        self.inspection_error = False
        self.up_error = False
        self.up_hook = lambda: None
        self.current_state = {"Running": True, "Health": {"Status": "healthy"}}
        self.calls = []
        self.up_calls = []
        self.inspect_calls = 0
        self.stdout = io.StringIO()
        self.stderr = io.StringIO()
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.stack.enter_context(patch.object(self.mod.subprocess, "check_output", self.docker_output))
        self.stack.enter_context(patch.object(self.mod.subprocess, "run", self.docker_up))
        self.stack.enter_context(patch.object(self.mod.os, "chown"))
        self.fchown = self.stack.enter_context(patch.object(self.mod.os, "fchown"))
        self.stack.enter_context(patch.object(self.mod.time, "sleep"))
        self.stack.enter_context(patch.object(self.mod.time, "monotonic", return_value=0))
        # Directory custody is synthetic; file bytes and mode checks are real.
        real_stat = Path.stat
        key_dir = self.mod.KEY.parent

        def fixture_stat(path, *args, **kwargs):
            result = real_stat(path, *args, **kwargs)
            if path in (key_dir, self.mod.KEY):
                fields = list(result)
                fields[4] = 99
                if path == self.mod.KEY:
                    fields[5] = 1000
                return os.stat_result(fields)
            return result

        self.stack.enter_context(patch.object(Path, "stat", fixture_stat))
        self.stack.enter_context(contextlib.redirect_stdout(self.stdout))
        self.stack.enter_context(contextlib.redirect_stderr(self.stderr))

    def model(self):
        service = self.component
        return {
            "name": "fixture-project",
            "services": {
                service: {
                    "image": self.mod.BASES[service],
                    "environment": {"UNRELATED_FIXTURE": "preserve"},
                    "volumes": [{"type": "bind", "source": "fixture-data", "target": "/data", "read_only": False}],
                },
                "other-persona": {"image": "fixture-unchanged", "environment": {"FIXTURE": "untouched"}},
            },
            "networks": {"default": {"name": "fixture-net"}},
        }

    def docker_output(self, argv, text=True):
        self.calls.append(list(argv))
        if argv[:2] == ("docker", "inspect"):
            self.inspect_calls += 1
            if self.inspect_calls == 1:
                return json.dumps([{
                    "Image": self.mod.BASES[self.component],
                    "Id": "fixture-old",
                    "Config": {"Labels": {
                        "com.docker.compose.service": self.component,
                        "com.docker.compose.project": "fixture-project",
                        "com.docker.compose.project.config_files": ",".join(map(str, self.inputs)),
                        "com.docker.compose.project.working_dir": str(self.root),
                    }},
                }])
            if self.inspection_error:
                raise subprocess.CalledProcessError(1, argv)
            return json.dumps([{"Image": self.mod.IMAGES[self.component], "Id": "fixture-new", "State": self.current_state}])
        if argv[:3] == ("docker", "image", "inspect"):
            return "[{}]"
        if argv[:2] == ("docker", "compose") and argv[-3:] == ("config", "--format", "json"):
            model = self.model()
            override = self.mod.STATE / (self.component + ".override.json")
            if str(override) in argv:
                spec = json.loads(override.read_text())["services"][self.component]
                target = model["services"][self.component]
                target["image"] = spec["image"]
                target["environment"].update(spec.get("environment", {}))
                target["volumes"].extend(spec.get("volumes", []))
                # Compose can reorder mounts and normalize default bind options.
                target["volumes"].reverse()
                if self.component == "server":
                    for mount in target["volumes"]:
                        if mount["target"].startswith("/run/secrets/"):
                            mount["bind"] = {"create_host_path": True}
                self.mutate_after(model)
            return json.dumps(model)
        raise AssertionError("Unexpected subprocess output call: " + repr(argv))

    def docker_up(self, argv, check):
        self.assertTrue(check)
        self.assertEqual(argv[:2], ["docker", "compose"])
        self.assertIn("up", argv)
        self.up_calls.append(list(argv))
        if len(self.up_calls) == 1:
            self.up_hook()
            if self.up_error:
                raise subprocess.CalledProcessError(1, argv)
        return subprocess.CompletedProcess(argv, 0)

    def activate(self, component="moss"):
        self.component = component
        if component == "moss":
            self.mod.KEY.parent.mkdir(exist_ok=True)
            self.mod.KEY.write_bytes(b"x" * 32)
            self.mod.KEY.chmod(0o640)
        with patch("sys.argv", [str(SCRIPT), "--component", component]):
            self.mod.main()

    def receipt(self):
        return json.loads((self.mod.STATE / (self.component + ".receipt.json")).read_text())

    def test_moss_allowlisted_image_and_config_change(self):
        self.activate()
        self.assertEqual(len(self.up_calls), 1)
        self.assertEqual(self.receipt()["status"], "applied-ready-not-accepted")
        self.assertIn(b"request-or-external", self.mod.CONFIG.read_bytes())
        self.assertNotIn("UNRELATED_FIXTURE", self.stdout.getvalue() + self.stderr.getvalue())
        self.assertEqual(self.fchown.call_count, 0)
        for path in self.inputs:
            self.assertIn(str(path), self.up_calls[0])

    def test_server_allowlisted_optin_and_key(self):
        old_umask = os.umask(0o022)
        try:
            self.activate("server")
        finally:
            os.umask(old_umask)
        self.assertEqual(self.mod.KEY.stat().st_size, 32)
        self.assertEqual(stat.S_IMODE(self.mod.KEY.stat().st_mode), 0o640)
        self.fchown.assert_called_once()
        self.assertEqual(self.fchown.call_args.args[1:], (99, 1000))
        spec = json.loads((self.mod.STATE / "server.override.json").read_text())["services"]["server"]
        self.assertEqual(spec["environment"]["PAPERCLIP_EXTERNAL_ORIGIN_COMPANY_ID"], self.mod.COMPANY)
        self.assertEqual(spec["environment"]["PAPERCLIP_EXTERNAL_ORIGIN_AGENT_ID"], self.mod.AGENT)
        self.assertTrue(spec["volumes"][0]["read_only"])
        self.assertEqual(self.mod.CONFIG.read_bytes(), self.original_config)

    def test_other_persona_change_blocks_before_deploy(self):
        self.mutate_after = lambda m: m["services"]["other-persona"].update(image="unexpected")
        with self.assertRaises(SystemExit):
            self.activate()
        self.assertEqual(self.up_calls, [])
        self.assertEqual(self.mod.CONFIG.read_bytes(), self.original_config)

    def test_network_change_blocks_before_deploy(self):
        self.mutate_after = lambda m: m["networks"]["default"].update(name="unexpected")
        with self.assertRaises(SystemExit):
            self.activate()
        self.assertEqual(self.up_calls, [])

    def test_unrelated_target_environment_change_blocks(self):
        self.mutate_after = lambda m: m["services"]["moss"]["environment"].update(UNRELATED_FIXTURE="unexpected")
        with self.assertRaises(SystemExit):
            self.activate()
        self.assertEqual(self.up_calls, [])

    def test_old_mount_change_blocks_before_deploy(self):
        def mutate(model):
            for mount in model["services"]["server"]["volumes"]:
                if mount["target"] == "/data":
                    mount["read_only"] = True
        self.mutate_after = mutate
        with self.assertRaises(SystemExit):
            self.activate("server")
        self.assertEqual(self.up_calls, [])

    def test_key_chown_failure_blocks_before_deploy(self):
        self.fchown.side_effect = PermissionError("fixture chown denied")
        with self.assertRaises(PermissionError):
            self.activate("server")
        self.assertEqual(self.up_calls, [])
        self.assertEqual(self.mod.KEY.stat().st_size, 0)

    def test_key_mode_is_640_even_with_restrictive_umask(self):
        old_umask = os.umask(0o077)
        try:
            self.activate("server")
        finally:
            os.umask(old_umask)
        self.assertEqual(stat.S_IMODE(self.mod.KEY.stat().st_mode), 0o640,
                         "API gid 1000 cannot read mode 0600")

    def test_bad_config_preimage_blocks_before_deploy(self):
        self.mod.CONFIG.write_bytes(b"fixture: different\n")
        with self.assertRaises(SystemExit):
            self.activate()
        self.assertEqual(self.up_calls, [])
        self.assertEqual(self.mod.CONFIG.read_bytes(), b"fixture: different\n")

    def test_inconclusive_readiness_does_not_rollback(self):
        self.current_state = {"Running": True, "Health": {"Status": "starting"}}
        with patch.object(self.mod.time, "monotonic", side_effect=[0, 0, 151]):
            with self.assertRaisesRegex(SystemExit, "inconclusive"):
                self.activate()
        self.assertEqual(len(self.up_calls), 1)
        self.assertEqual(self.receipt()["status"], "applied-readiness-inconclusive")
        self.assertIn(b"request-or-external", self.mod.CONFIG.read_bytes())

    def test_actual_stopped_service_rolls_back_config_and_image(self):
        self.current_state = {"Running": False}
        with self.assertRaisesRegex(RuntimeError, "essential"):
            self.activate()
        self.assertEqual(len(self.up_calls), 2)
        self.assertEqual(self.mod.CONFIG.read_bytes(), self.original_config)
        rollback = json.loads((self.mod.STATE / "moss.rollback.json").read_text())
        self.assertEqual(rollback["services"]["moss"]["image"], self.mod.BASES["moss"])
        self.assertNotIn(str(self.mod.STATE / "moss.override.json"), self.up_calls[-1])

    def test_inspect_transport_error_does_not_rollback_healthy_service(self):
        self.inspection_error = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.activate()
        self.assertEqual(len(self.up_calls), 1, "failed observation is not actual service failure")

    def test_compose_nonzero_reconciles_healthy_service_before_rollback(self):
        self.up_error = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.activate()
        self.assertGreaterEqual(self.inspect_calls, 2, "read actual container after Compose error")
        self.assertEqual(len(self.up_calls), 1)

    def test_recovery_receipt_requires_previous_image_health_readback(self):
        self.current_state = {"Running": False}
        with self.assertRaises(RuntimeError):
            self.activate()
        # Fixture would still report wrong image/stopped after rollback; do not
        # claim recovered simply because Compose returned zero.
        self.assertNotEqual(self.receipt()["status"], "startup-failed-recovered-previous-image")

    def test_concurrent_config_change_is_not_overwritten_by_recovery(self):
        concurrent = b"fixture: concurrent-author-change\n"
        self.current_state = {"Running": False}
        self.up_hook = lambda: self.mod.CONFIG.write_bytes(concurrent)
        with self.assertRaisesRegex(RuntimeError, "concurrently"):
            self.activate()
        self.assertEqual(len(self.up_calls), 1)
        self.assertEqual(self.mod.CONFIG.read_bytes(), concurrent)


if __name__ == "__main__":
    unittest.main()
