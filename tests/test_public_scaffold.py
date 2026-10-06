import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest
from privacy_guard import Gate

ROOT = Path(__file__).resolve().parents[1]
AGENTS = {'moss', 'jen', 'denholm', 'roy', 'richmond', 'the-elders'}


class ScaffoldTests(unittest.TestCase):
    def test_compose_is_valid_json_yaml_and_agnostic(self):
        # JSON is a YAML subset: validate syntax with stdlib, no Docker/YAML
        # package requirement. This is source validation, not a Compose render.
        model = json.loads((ROOT / 'compose.yaml').read_text())
        self.assertEqual(set(model['services']), AGENTS)
        self.assertEqual(model['networks'], {'internal': {'internal': True}})
        example = dict(line.split('=', 1) for line in (ROOT / '.env.example').read_text().splitlines()
                       if line and not line.startswith('#'))
        required = set()
        for agent, service in model['services'].items():
            self.assertFalse(set(service) & {'build', 'ports', 'env_file', 'command', 'entrypoint', 'user', 'container_name'})
            prefix = agent.upper().replace('-', '_')
            self.assertTrue(service['image'].startswith('${' + prefix + '_IMAGE:?'))
            self.assertEqual(service['networks'], ['internal'])
            self.assertEqual(service['environment'], {'AGENT_NAME': agent, 'HERMES_HOME': '/runtime', 'TERMINAL_CWD': '/workspace'})
            mounts = {v['target']: v for v in service['volumes']}
            self.assertEqual(set(mounts), {'/runtime', '/workspace', '/contracts'})
            for target, suffix in [('/runtime', 'RUNTIME_ROOT'), ('/workspace', 'WORKSPACE_ROOT')]:
                mount = mounts[target]
                self.assertEqual(mount['type'], 'bind')
                self.assertEqual(mount['bind'], {'create_host_path': False})
                self.assertTrue(mount['source'].startswith('${' + prefix + '_' + suffix + ':?'))
            contract = mounts['/contracts']
            self.assertTrue(contract['read_only'])
            self.assertEqual(contract['source'], './agents/public/' + agent)
            self.assertTrue((ROOT / contract['source']).is_dir())
            required.update(re.findall(r'\$\{([A-Z_]+):\?', json.dumps(service)))
        self.assertEqual(required, set(example))
        self.assertEqual(len(required), 18)

    def test_project_overlay_is_single_readonly_mount(self):
        overlay = json.loads((ROOT / 'compose.project-mount.example.yaml').read_text())
        self.assertEqual(set(overlay['services']), {'moss'})
        mounts = overlay['services']['moss']['volumes']
        self.assertEqual(len(mounts), 1)
        mount = mounts[0]
        self.assertEqual(mount['target'], '/workspace/projects/example-project')
        self.assertTrue(mount['read_only'])
        self.assertFalse(mount['bind']['create_host_path'])
        self.assertIn('${HERMES_EXAMPLE_PROJECTS_ROOT:?', mount['source'])

    def test_operational_families_are_absent(self):
        for name in ['moss-interactive-deploy', 'moss-unified', 'moss-antigravity',
                     'moss-latest-host.md', 'providers', 'build-inputs', 'supervisor',
                     'delegation-categories', 'release', 'overlays']:
            path = ROOT / 'ops' / name
            self.assertFalse(path.is_file() or (path.is_dir() and any(p.is_file() or p.is_symlink() for p in path.rglob('*'))), name)
        self.assertFalse((ROOT / 'ops/deploy-moss-all-in-one.sh').exists())
        self.assertFalse((ROOT / 'ops/install-runtime-backup-retention.sh').exists())
        self.assertTrue((ROOT / 'ops/runtime-backup-retention.py').is_file())

    def test_schemas_and_public_examples(self):
        cp = subprocess.run(['bash', 'tests/validate-schemas.sh'], cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(cp.returncode, 0, cp.stdout + cp.stderr)
        self.assertIn('schema_validation_ok', cp.stdout)

    def test_public_ignore_boundary(self):
        text = (ROOT / '.gitignore').read_text()
        for name in ('/private/', '/agents/private/', '/runtime/'):
            self.assertIn(name, text)
        tracked = subprocess.check_output(['git', 'ls-files', '--', 'private', 'agents/private', 'runtime', 'state'], cwd=ROOT)
        self.assertFalse(tracked)

    def test_offline_entrypoint_has_no_runtime_dependencies(self):
        script = (ROOT / 'tests/run-all.sh').read_text()
        self.assertNotIn('docker', script)
        self.assertNotIn('HERMES_TEST_IMAGE', script)
        self.assertIn('privacy_guard.py --mode tree', script)
        self.assertIn('git diff --check', script)

    def test_exact_candidate_archive_without_source_commit(self):
        # The actual candidate, including new files and pending removals, is
        # copied into a disposable Git index. write-tree is not a commit/ref.
        paths = subprocess.check_output(['git', 'ls-files', '--cached', '--others',
                                         '--exclude-standard', '-z'], cwd=ROOT).split(b'\0')
        with tempfile.TemporaryDirectory() as td:
            snapshot = Path(td)
            for raw in set(paths) - {b''}:
                source = ROOT / os.fsdecode(raw)
                if not source.exists() and not source.is_symlink():
                    continue
                target = snapshot / os.fsdecode(raw)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target, follow_symlinks=False)
            subprocess.run(['git', 'init', '-q', '-b', 'fixture'], cwd=snapshot, check=True)
            subprocess.run(['git', 'add', '-A'], cwd=snapshot, check=True)
            tree = subprocess.check_output(['git', 'write-tree'], cwd=snapshot).decode().strip()
            gate = Gate()
            gate.archive(snapshot, tree)
            self.assertTrue(gate.report()['ok'], gate.report())


if __name__ == '__main__':
    unittest.main()
