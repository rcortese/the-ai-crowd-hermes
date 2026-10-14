"""Operational lint CLI: synthetic inputs only; never contacts Docker or loads profiles."""
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
LINT = ROOT / 'tests/lint_compose_env.py'


class OperationalLintTests(unittest.TestCase):
    def model(self):
        return {'services': {'worker': {'image': '${IMAGE:?required}',
                'env_file': ['./common.env', './worker.env'],
                'environment': {'API_TOKEN': '${WORKER_TOKEN:-}',
                                'ARTIFACT_SHA256': 'a' * 64,
                                'EMPTY': '',
                                'PROFILE_PROXY_PEER_API_KEY_ENV': 'API_TOKEN',
                                'VALUE': '${VALUE-default}'}}}}

    def catalog(self):
        names = self.model()['services']['worker']['environment']
        return {'version': 1, 'services': {'worker': {
            'environment': {k: {'status': 'keep', 'consumer': 'synthetic fixture contract'} for k in names},
            'env_file': ['./common.env', './worker.env'], 'overrides': ['EMPTY']}},
            'env_files': {f: {k: {'status': 'uncertain', 'consumer': 'synthetic file-only contract'} for k in names}
                          for f, names in {'./common.env': ['EMPTY', 'SHARED'], './worker.env': ['LOCAL']}.items()}}

    def run_case(self, candidate=None, baseline=None, catalog=None, raw=None):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            for name, data in [('candidate', candidate if candidate is not None else self.model()),
                               ('baseline', baseline if baseline is not None else self.model()),
                               ('catalog', catalog if catalog is not None else self.catalog())]:
                (root / name).write_text(raw if name == 'candidate' and raw is not None else json.dumps(data))
            return subprocess.run([sys.executable, str(LINT), '--scope', 'operational',
                '--compose', str(root / 'candidate'), '--baseline', str(root / 'baseline'),
                '--contract', str(root / 'catalog')], capture_output=True, text=True)

    def reject(self, diagnostic, **kwargs):
        r = self.run_case(**kwargs)
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn(diagnostic, r.stderr)
        self.assertNotIn('Traceback', r.stderr)
        return r

    def test_operational_model_and_yaml_pass(self):
        self.assertEqual(self.run_case().returncode, 0)
        raw = '''services:
  worker:
    image: '${IMAGE:?required}'
    env_file: ['./common.env', './worker.env']
    environment:
      API_TOKEN: '${WORKER_TOKEN:-}'
      ARTIFACT_SHA256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      EMPTY: ''
      PROFILE_PROXY_PEER_API_KEY_ENV: API_TOKEN
      VALUE: '${VALUE-default}'
'''
        r = self.run_case(raw=raw)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_duplicate_merge_and_alias_fail_before_overwrite(self):
        self.reject('duplicate-key', raw='services: {}\nservices: {}\n')
        self.reject('duplicate-key', raw='services:\n  worker:\n    environment:\n      VALUE: a\n      VALUE: b\n')
        self.reject('merge-key', raw='services:\n  worker:\n    <<: {image: x}\n')
        self.reject('alias', raw='services:\n  worker: &w {}\n  other: *w\n')

    def test_nonstring_null_list_and_order_fail(self):
        for value in [None, True, 1, [], {}]:
            m = self.model(); m['services']['worker']['environment']['VALUE'] = value
            self.reject('string-required', candidate=m)
        m = self.model(); m['services']['worker']['environment'] = ['VALUE']
        self.reject('mapping-required', candidate=m)
        m = self.model(); e = m['services']['worker']['environment']
        m['services']['worker']['environment'] = dict(reversed(list(e.items())))
        self.reject('environment-order', candidate=m)

    def test_baseline_list_and_numeric_values_can_be_normalized(self):
        b = self.model(); b['services']['worker']['environment']['VALUE'] = 42
        b['services']['worker']['environment'] = [k + '=' + str(v) for k, v in b['services']['worker']['environment'].items()]
        m = self.model(); m['services']['worker']['environment']['VALUE'] = '42'
        r = self.run_case(candidate=m, baseline=b)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_exact_bindings_defaults_required_and_other_fields_preserved(self):
        for value in ['${VALUE:-default}', '${VALUE:?required}', '', '${OTHER-default}']:
            m = self.model(); m['services']['worker']['environment']['VALUE'] = value
            self.reject('semantic-drift', candidate=m)
        m = self.model(); m['services']['worker']['image'] = '${IMAGE:-fallback}'
        self.reject('semantic-drift', candidate=m)
        m = self.model(); del m['services']['worker']['environment']['EMPTY']
        self.reject('environment-set', candidate=m)

    def test_env_file_order_presence_and_unknown_names(self):
        m = self.model(); m['services']['worker']['env_file'].reverse()
        self.reject('env-file-order', candidate=m)
        c = self.catalog(); del c['env_files']['./worker.env']
        self.reject('env-file-uninventoried', catalog=c)
        m = self.model(); m['services']['worker']['environment']['NEW'] = 'x'
        self.reject('environment-set', candidate=m)

    def test_layer_duplicates_need_explicit_review_even_for_empty_override(self):
        c = self.catalog(); c['services']['worker']['overrides'] = []
        self.reject('unreviewed-layer-override', catalog=c)
        c = self.catalog(); c['env_files']['./worker.env']['SHARED'] = {'status': 'keep', 'consumer': 'reviewed duplicate'}
        self.reject('unreviewed-layer-override', catalog=c)
        c['services']['worker']['overrides'].append('SHARED')
        self.assertEqual(self.run_case(catalog=c).returncode, 0)

    def test_dynamic_proxy_requires_delivered_name(self):
        m = self.model(); m['services']['worker']['environment']['PROFILE_PROXY_PEER_API_KEY_ENV'] = 'MISSING'
        self.reject('indirection-missing', candidate=m)

    def test_secret_diagnostics_omit_values_keys_and_parser_snippets(self):
        marker = 'synthetic-sensitive-marker'
        m = self.model(); m['services']['worker']['environment']['API_TOKEN'] = marker
        r = self.reject('secret-literal', candidate=m)
        self.assertNotIn(marker, r.stdout + r.stderr)
        m['services']['worker']['environment']['API_TOKEN'] = '${WORKER_TOKEN:-' + marker + '}'
        r = self.reject('secret-literal', candidate=m)
        self.assertNotIn(marker, r.stdout + r.stderr)
        r = self.reject('yaml-syntax', raw='services: ["' + marker)
        self.assertNotIn(marker, r.stdout + r.stderr)
        m = self.model(); m['services'][marker] = {}
        r = self.reject('service-set', candidate=m)
        self.assertNotIn(marker, r.stdout + r.stderr)

    def test_non_environment_scalar_types_are_preserved(self):
        for old, new in [(1, True), (True, 1), (0, False), (1, 1.0)]:
            b = self.model(); m = self.model()
            b['services']['worker']['deploy'] = {'replicas': old}
            m['services']['worker']['deploy'] = {'replicas': new}
            self.reject('semantic-drift', candidate=m, baseline=b)

    def test_invalid_digest_and_file_only_missing_metadata_fail(self):
        m = self.model(); m['services']['worker']['environment']['ARTIFACT_SHA256'] = 'synthetic-plaintext'
        self.reject('secret-literal', candidate=m, baseline=m)
        c = self.catalog(); c['env_files']['./worker.env']['LOCAL'] = {}
        self.reject('consumer-contract', catalog=c)

    def test_constructor_errors_never_emit_tracebacks(self):
        for raw, diagnostic in [('services: {worker: {date: 2026-99-01}}', 'yaml-syntax'), ('? [a, b]\n: value\n', 'mapping-key')]:
            r = self.reject(diagnostic, raw=raw)
            self.assertNotIn(str(ROOT), r.stderr)

    def test_normalizer_expands_baseline_inheritance_and_refuses_overwrite(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            baseline = root / 'baseline'
            output = root / 'candidate'
            baseline.write_text('x-base: &base {image: example, environment: {VALUE: 42}}\nservices:\n  worker:\n    <<: *base\n')
            cmd = [sys.executable, str(ROOT / 'tests/normalize_compose_env.py'), '--baseline', str(baseline), '--output', str(output)]
            r = subprocess.run(cmd, capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(json.loads(output.read_text())['services']['worker']['environment'], {'VALUE': '42'})
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)
            prior = output.read_bytes()
            self.assertEqual(subprocess.run(cmd, capture_output=True).returncode, 1)
            self.assertEqual(output.read_bytes(), prior)
            baseline.write_text('? [a,b]\n: value\n')
            cmd[-1] = str(root / 'another')
            r = subprocess.run(cmd, capture_output=True, text=True)
            self.assertEqual(r.returncode, 1)
            self.assertNotIn('Traceback', r.stderr)

    def test_missing_consumer_disposition_fails(self):
        c = self.catalog(); c['services']['worker']['environment']['VALUE'] = {'status': 'remove'}
        self.reject('consumer-contract', catalog=c)


if __name__ == '__main__':
    unittest.main()
