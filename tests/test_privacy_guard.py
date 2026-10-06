import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('privacy_guard.py')
spec = importlib.util.spec_from_file_location('privacy_guard', SCRIPT)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PrivacyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        self.git('init', '-q', '-b', 'main')
        self.git('config', 'user.name', 'Synthetic Author')
        self.git('config', 'user.email', 'fixture@example.invalid')
        self.save('README.md', 'synthetic public fixture\n')
        self.commit()

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.repo, stderr=subprocess.DEVNULL)

    def save(self, name, text):
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def commit(self, message='synthetic fixture'):
        self.git('add', '-A')
        self.git('commit', '-qm', message)

    def gate(self, mode='all'):
        cp = subprocess.run(['python3', str(SCRIPT), '--repo', str(self.repo), '--mode', mode],
                            capture_output=True, text=True)
        self.assertIn(cp.returncode, (0, 1), cp.stderr)
        return cp, json.loads(cp.stdout)

    def test_clean_tree_archive_and_history(self):
        cp, result = self.gate()
        self.assertEqual(cp.returncode, 0, cp.stdout)
        self.assertEqual(result['counts']['commits'], 1)

    def test_dirty_tree_is_not_head(self):
        self.save('pending.txt', '/' + 'mnt/' + 'user/fixture')
        self.assertEqual(self.gate('tree')[0].returncode, 1)
        self.assertEqual(self.gate('archive')[0].returncode, 0)

    def test_deleted_blob_still_fails_history(self):
        self.save('deleted.txt', '192.' + '168.42.99')
        self.commit()
        (self.repo / 'deleted.txt').unlink()
        self.commit()
        self.assertEqual(self.gate('tree')[0].returncode, 0)
        self.assertEqual(self.gate('history')[0].returncode, 1)

    def test_non_main_head_is_scanned(self):
        self.git('checkout', '-qb', 'side')
        self.save('side.txt', 'fixture' + '.lan')
        self.commit()
        self.git('checkout', '-q', 'main')
        self.assertEqual(self.gate('history')[0].returncode, 1)

    def test_tag_only_commit_and_annotated_message(self):
        self.git('checkout', '--orphan', 'orphan')
        self.save('old.txt', '192.' + '168.33.77')
        self.commit()
        self.git('tag', '-a', 'archived', '-m', 'fixture' + '.lan')
        self.git('checkout', '-q', 'main')
        self.git('branch', '-D', 'orphan')
        cp, report = self.gate('history')
        self.assertEqual(cp.returncode, 1)
        self.assertIn('history-tag', {f['surface'] for f in report['findings']})
        self.assertIn('history-blob', {f['surface'] for f in report['findings']})

    def test_commit_message_is_scanned(self):
        self.git('commit', '--allow-empty', '-qm', 'fixture' + '.lan')
        self.assertEqual(self.gate('history')[0].returncode, 1)

    def test_redaction_includes_sensitive_paths(self):
        secret = 'sk-' + 'syntheticCredentialValue123456'
        name = 'fixture' + '.lan.txt'
        self.save(name, secret)
        cp, report = self.gate('tree')
        self.assertEqual(cp.returncode, 1)
        self.assertNotIn(secret, cp.stdout + cp.stderr)
        self.assertNotIn(name, cp.stdout + cp.stderr)
        self.assertTrue(report['findings'])

    def test_export_ignore_cannot_hide_tracked_secret(self):
        self.save('hidden.txt', '/' + 'mnt/' + 'user/fixture')
        self.save('.gitattributes', 'hidden.txt export-ignore\n')
        self.commit()
        cp, report = self.gate('archive')
        self.assertEqual(cp.returncode, 1)
        self.assertIn('tracked-archive-parity', {f['rule'] for f in report['findings']})
        self.assertIn('host-storage', {f['rule'] for f in report['findings']})

    def test_export_subst_byte_parity(self):
        self.save('version.txt', '$Format:%H$\n')
        self.save('.gitattributes', 'version.txt export-subst\n')
        self.commit()
        cp, report = self.gate('archive')
        self.assertEqual(cp.returncode, 1)
        self.assertIn('tracked-archive-bytes', {f['rule'] for f in report['findings']})

    def test_gitlink_even_when_archive_omits_it(self):
        oid = self.git('rev-parse', 'HEAD').decode().strip()
        self.git('update-index', '--add', '--cacheinfo', '160000,' + oid + ',dependency')
        self.git('commit', '-qm', 'gitlink fixture')
        for mode in ('tree', 'archive', 'history'):
            cp, report = self.gate(mode)
            self.assertEqual(cp.returncode, 1, mode)
            self.assertIn('gitlink', {f['rule'] for f in report['findings']})

    def test_protected_roots_even_for_benign_bytes(self):
        for name in ('private/note.txt', 'runtime/note.txt', 'state/note.txt', 'agents/private/note.txt', 'nested/sessions/note.txt'):
            self.save(name, 'benign')
        self.commit()
        for mode in ('tree', 'archive', 'history'):
            self.assertEqual(self.gate(mode)[0].returncode, 1, mode)

    def test_symlink_escape_is_rejected(self):
        (self.repo / 'link').symlink_to('../outside')
        self.commit()
        for mode in ('tree', 'archive'):
            self.assertEqual(self.gate(mode)[0].returncode, 1)

    def test_detectors_use_synthetic_fragments(self):
        cases = ['Rodo' + 'lfo', '/' + 'root/fixture', 'media' + ':/fixture',
                 'Session ' + 'abcdef123456', 'api_key=' + 'x' * 24,
                 '-----BEGIN ' + 'PRIVATE KEY-----', '10.' + '2.3.4', '172.' + '20.3.4']
        for value in cases:
            gate = module.Gate()
            gate.scan('fixture', 'synthetic', value.encode())
            self.assertTrue(gate.findings, value)

    def test_git_failure_is_redacted_and_fail_closed(self):
        bad = self.repo / 'not-repo'
        bad.mkdir()
        cp = subprocess.run(['python3', str(SCRIPT), '--repo', str(bad / 'absent')], capture_output=True, text=True)
        self.assertEqual(cp.returncode, 1)
        self.assertNotIn(str(bad), cp.stdout + cp.stderr)
        self.assertIn('inspection-error', cp.stdout)

    def test_shallow_history_cannot_claim_clean(self):
        oid = self.git('rev-parse', 'HEAD').decode().strip()
        self.save('.git/shallow', oid + '\n')
        cp, report = self.gate('history')
        self.assertEqual(cp.returncode, 1)
        self.assertIn('shallow-history', {f['rule'] for f in report['findings']})

    def test_replace_ref_cannot_hide_commit_message(self):
        original = self.git('rev-parse', 'HEAD').decode().strip()
        self.git('commit', '--allow-empty', '-qm', 'fixture' + '.lan')
        bad = self.git('rev-parse', 'HEAD').decode().strip()
        self.git('replace', bad, original)
        self.assertEqual(self.gate('history')[0].returncode, 1)

    def test_withdrawn_families_fail_even_with_benign_content(self):
        self.save('ops/providers/synthetic.py', 'print(1)\n')
        self.commit()
        cp, report = self.gate('all')
        self.assertEqual(cp.returncode, 1)
        self.assertIn('withdrawn-operational-path', {f['rule'] for f in report['findings']})

    def test_known_contacts_and_sessions(self):
        for value in ['85034' + '64394', '@the_ai_' + 'crowd_jen_bot',
                      'b74895' + 'c5f7f3', '7cf' + '9865' + 'dd435',
                      'TELEGRAM_ALLOWED_USERS=' + '1234567', '1234567:' + 'A' * 35]:
            gate = module.Gate()
            gate.scan('fixture', 'synthetic', value.encode())
            self.assertTrue(gate.findings)

    def test_unquoted_environment_reference_is_not_a_credential(self):
        gate = module.Gate()
        gate.scan('fixture', 'synthetic', b'api_key: os.environ/EXAMPLE_API_KEY')
        self.assertFalse(gate.findings)

    def test_digest_denial_outside_assignment_and_split_shell_quotes(self):
        import hashlib
        from unittest.mock import patch
        fixture = ('ab' * 18).encode()
        digest = hashlib.sha256(fixture).hexdigest()
        with patch.object(module, 'BLOCKED_LITERAL_SHA256', frozenset({digest})):
            for data in (b'printf "' + fixture + b'"',
                         b"value='" + fixture[:18] + b"''" + fixture[18:] + b"'"):
                gate = module.Gate()
                gate.scan('fixture', 'synthetic', data)
                self.assertIn('blocked-literal-digest', {x[2] for x in gate.findings})
                self.assertNotIn(fixture.decode(), json.dumps(gate.report()))
            gate = module.Gate()
            gate.scan('fixture', 'synthetic', b'cd' * 18)
            self.assertFalse(gate.findings)

    def test_json_credential_values_are_not_missed(self):
        for key in ('api_key', 'access_token', 'refresh_token', 'id_token', 'password'):
            gate = module.Gate()
            gate.scan('fixture', 'synthetic', json.dumps({key: 'A' * 28}).encode())
            self.assertTrue(gate.findings, key)


if __name__ == '__main__':
    unittest.main()
