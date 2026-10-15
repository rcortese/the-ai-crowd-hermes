#!/usr/bin/env python3
"""Dependency-free negative/build custody tests; Docker is always a fake executable."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('components', HERE / 'build_components.py')
assert spec and spec.loader
components = importlib.util.module_from_spec(spec)
spec.loader.exec_module(components)


class DeliveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='official-paperclip-tests-', dir=os.environ['TMPDIR'])
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.input = self.root / 'input'
        self.input.mkdir()
        (self.input / 'execute.ts').write_text('fixture')
        (self.input / 'paperclip-mcp.tar.gz').write_bytes(b'fixture')
        self.manifest = {'source': json.loads((HERE / 'source.json').read_text()), 'lockedRelease': True,
                         'runtimeLockSha256': components.digest(HERE / 'runtime-package-lock.json'),
                         'artifacts': {p.name: {'sha256': components.digest(p)} for p in self.input.iterdir()}}
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        docker = self.bin / 'docker'
        docker.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$FAKE_DOCKER_LOG"\nexit 0\n')
        docker.chmod(0o755)
        self.log = self.root / 'docker.log'

    def reject(self, reason, *extra, docker=False):
        (self.input / 'manifest.json').write_text(json.dumps(self.manifest))
        result = subprocess.run([sys.executable, str(HERE / 'build_image.py'),
                                 '--docker-host', 'unix:///fixture-never-real.sock',
                                 '--components', str(self.input), '--role', 'moss',
                                 '--out', str(self.root / 'output'),
                                 '--tag', 'fixture:tac246-test', *extra],
                                env={**os.environ, 'PATH': str(self.bin), 'FAKE_DOCKER_LOG': str(self.log)},
                                text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stderr.strip(), reason)
        self.assertFalse((self.root / 'output').exists())
        self.assertEqual(self.log.exists(), docker)
        if docker:
            self.assertEqual(self.log.read_text(), 'image inspect fixture:tac246-test\n')

    def test_unlocked_resolution_is_not_a_release(self):
        self.manifest['lockedRelease'] = False
        self.reject('source_or_locked_release_mismatch')

    def test_corrupt_artifact_stops_before_docker(self):
        (self.input / 'execute.ts').write_text('corruption')
        self.reject('artifact_integrity_mismatch')

    def test_runtime_lock_mismatch_stops_before_docker(self):
        self.manifest['runtimeLockSha256'] = '0' * 64
        self.reject('runtime_lock_mismatch')

    def test_mutable_base_stops_before_docker(self):
        self.reject('immutable_base_required', '--base', 'image:latest')

    def test_wrong_adapter_base_stops_before_docker(self):
        self.reject('adapter_base_mismatch', '--role', 'adapter', '--base', 'sha256:' + '0' * 64)

    def test_existing_candidate_tag_is_not_repointed(self):
        self.reject('candidate_tag_already_exists', docker=True)

    def test_tar_is_deterministic(self):
        tree = self.root / 'tree'
        tree.mkdir()
        path = tree / 'hello'
        path.write_text('content')
        first, second = self.root / 'first.tgz', self.root / 'second.tgz'
        components.pack_tree(tree, first, 'package')
        os.utime(path, (12345, 12345))
        components.pack_tree(tree, second, 'package')
        self.assertEqual(first.read_bytes(), second.read_bytes())

    def test_tar_rejects_absolute_internal_link(self):
        tree = self.root / 'tree'
        tree.mkdir()
        (tree / 'file').write_text('content')
        (tree / 'link').symlink_to(tree / 'file')
        with self.assertRaisesRegex(ValueError, 'absolute symlink'):
            components.pack_tree(tree, self.root / 'archive.tgz', 'package')

    def test_tar_rejects_relative_escape(self):
        tree = self.root / 'tree'
        tree.mkdir()
        (self.root / 'outside').write_text('content')
        (tree / 'link').symlink_to('../outside')
        with self.assertRaises(ValueError):
            components.pack_tree(tree, self.root / 'archive.tgz', 'package')


if __name__ == '__main__':
    unittest.main(verbosity=2)
