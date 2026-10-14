"""Public seam: offline linter CLI, with causal source mutations (no runtime)."""
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
LINT = ROOT / 'tests/lint_compose_env.py'


class ComposeEnvironmentLintTests(unittest.TestCase):
    def run_lint(self, source=None):
        if source is None:
            return subprocess.run([sys.executable, str(LINT)], capture_output=True, text=True)
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / 'compose.yaml'
            path.write_text(source)
            return subprocess.run([sys.executable, str(LINT), '--compose', str(path)],
                                  capture_output=True, text=True)

    def model(self):
        return json.loads((ROOT / 'compose.yaml').read_text())

    def assert_rejected(self, source, diagnostic):
        result = self.run_lint(source)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(diagnostic, result.stderr)
        self.assertNotIn('Traceback', result.stderr)
        return result

    def test_checked_in_source_passes(self):
        result = self.run_lint()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('compose_env_lint_ok', result.stdout)

    def test_duplicate_keys_are_not_silently_overwritten(self):
        for original, replacement in [
            ('"name":', '"name": "ignored", "name":'),
            ('"moss": {', '"moss": {}, "moss": {'),
            ('"AGENT_NAME":', '"AGENT_NAME": "ignored", "AGENT_NAME":'),
        ]:
            with self.subTest(original=original):
                source = (ROOT / 'compose.yaml').read_text().replace(original, replacement, 1)
                self.assert_rejected(source, 'duplicate-key')

    def test_yaml_merges_and_aliases_are_rejected_before_resolution(self):
        self.assert_rejected('x-env: &env\n  HERMES_HOME: /runtime\nservices:\n  moss:\n    environment:\n      <<: *env\n',
                             'json-subset')
        model = self.model()
        model['services']['moss']['environment']['<<'] = {'HERMES_HOME': '/elsewhere'}
        self.assert_rejected(json.dumps(model), 'merge-key')

    def test_non_string_and_implicit_passthrough_values_fail(self):
        for value in [None, True, 7, 1.5, [], {}]:
            with self.subTest(value=value):
                model = self.model()
                model['services']['moss']['environment']['HERMES_HOME'] = value
                self.assert_rejected(json.dumps(model), 'string-required')
        model = self.model()
        model['services']['moss']['environment'] = ['HERMES_HOME']
        self.assert_rejected(json.dumps(model), 'mapping-required')

    def test_unknown_missing_and_wrong_binding_fail(self):
        for mutation, diagnostic in [('unknown', 'unexpected-variable'),
                                     ('missing', 'missing-variable'),
                                     ('binding', 'binding-mismatch')]:
            model = self.model()
            env = model['services']['moss']['environment']
            if mutation == 'unknown':
                env['UNREVIEWED_OPTION'] = 'enabled'
            elif mutation == 'missing':
                del env['TERMINAL_CWD']
            else:
                env['AGENT_NAME'] = 'jen'
            self.assert_rejected(json.dumps(model), diagnostic)

    def test_environment_order_is_deterministic(self):
        model = self.model()
        env = model['services']['moss']['environment']
        model['services']['moss']['environment'] = dict(reversed(list(env.items())))
        self.assert_rejected(json.dumps(model), 'environment-order')

    def test_env_file_cannot_silently_change_delivery(self):
        model = self.model()
        model['services']['moss']['env_file'] = ['fleet.env']
        self.assert_rejected(json.dumps(model), 'env-file-not-in-scaffold')

    def test_required_interpolation_must_not_become_optional(self):
        model = self.model()
        model['services']['moss']['image'] = '${MOSS_IMAGE:-example.invalid/image}'
        self.assert_rejected(json.dumps(model), 'required-interpolation')
        model = self.model()
        model['services']['moss']['volumes'][0]['source'] = '${JEN_RUNTIME_ROOT:?wrong persona}'
        self.assert_rejected(json.dumps(model), 'required-interpolation')

    def test_literal_credentials_are_rejected_without_echo(self):
        model = self.model()
        marker = 'synthetic-' + 'credential-for-negative-test'
        model['services']['moss']['environment']['API_TOKEN'] = marker
        result = self.assert_rejected(json.dumps(model), 'secret-literal')
        self.assertNotIn(marker, result.stdout + result.stderr)
        # An integrity digest is not a credential, but still needs a consumer contract.
        model['services']['moss']['environment'].pop('API_TOKEN')
        model['services']['moss']['environment']['ARTIFACT_SHA256'] = 'a' * 64
        result = self.assert_rejected(json.dumps(model), 'unexpected-variable')
        self.assertNotIn('secret-literal', result.stderr)

    def test_wrong_service_set_and_malformed_documents_fail_cleanly(self):
        model = copy.deepcopy(self.model())
        del model['services']['jen']
        self.assert_rejected(json.dumps(model), 'service-set')
        for source in ['[]', '{', '{"services": []}']:
            with self.subTest(source=source):
                result = self.run_lint(source)
                self.assertEqual(result.returncode, 1)
                self.assertNotIn('Traceback', result.stderr)


if __name__ == '__main__':
    unittest.main()
