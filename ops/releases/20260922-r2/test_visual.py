import contextlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).with_name('run-visual.py')

class VisualTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        shutil.copy2(SOURCE, self.root / SOURCE.name)
        spec = importlib.util.spec_from_file_location('visual', self.root / SOURCE.name)
        self.v = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.v)
        self.v.STATE = self.root / 'transaction.json'

    def tearDown(self):
        self.tmp.cleanup()

    def invoke(self, mode, answer='APLICAR'):
        out = io.StringIO()
        with patch.object(sys, 'argv', ['run-visual.py', mode]), patch.object(self.v.os, 'geteuid', return_value=0), patch.object(self.v.socket, 'gethostname', return_value='MEDIA'), patch('builtins.input', return_value=answer), contextlib.redirect_stdout(out):
            rc = self.v.main()
        return rc, out.getvalue()

    def engine(self, code):
        (self.root / 'fleet_release.py').write_text(code)

    def test_success_and_saved_watch(self):
        self.engine("print('fixture: verified')\n")
        rc, out = self.invoke('apply')
        self.assertEqual(rc, 0)
        self.assertIn('fixture: verified', out)
        self.assertIn('CONCLUÍDO SEM ERRO', out)
        self.assertEqual(self.invoke('watch')[0], 0)

    def test_preflight_failure_is_visible_and_nonzero(self):
        self.engine("import sys\nprint('FAILED: fixture preflight', flush=True)\nsys.exit(7)\n")
        rc, out = self.invoke('apply')
        self.assertEqual(rc, 7)
        self.assertIn('FAILED: fixture preflight', out)
        self.assertIn('FALHOU', out)
        self.assertFalse(self.v.STATE.exists())

    def test_cancel_does_not_launch(self):
        self.engine("raise Exception('must not run')\n")
        self.assertEqual(self.invoke('apply', 'NAO')[0], 1)
        self.assertFalse((self.v.RUNS / 'latest.json').exists())

    def test_detach_survives_and_duplicate_attaches(self):
        self.engine("import time\nprint('begin', flush=True)\ntime.sleep(2)\nprint('end', flush=True)\n")
        real_watch = self.v.watch
        with patch.object(self.v, 'watch', return_value=130):
            self.assertEqual(self.invoke('apply')[0], 130)
        # Lock survives viewer exit; a second apply attaches, never asks for consent.
        with patch('builtins.input', side_effect=AssertionError('duplicate launch')):
            with patch.object(sys, 'argv', ['visual', 'apply']), patch.object(self.v.os, 'geteuid', return_value=0), patch.object(self.v.socket, 'gethostname', return_value='MEDIA'), contextlib.redirect_stdout(io.StringIO()) as out:
                self.assertEqual(self.v.main(), 0)
        self.assertIn('Já existe execução visual ativa', out.getvalue())
        self.assertEqual(len(list(self.v.RUNS.glob('run-*'))), 1)

    def test_missing_worker_is_not_success(self):
        directory = self.root / 'dead'
        directory.mkdir()
        (directory / 'output.log').write_text('')
        (directory / 'start.json').write_text(json.dumps({'pid': 999999999, 'identity': 'absent'}))
        with contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(self.v.watch(directory), 1)
        self.assertIn('INTERROMPIDO SEM RESULTADO', out.getvalue())

if __name__ == '__main__':
    unittest.main(verbosity=2)
