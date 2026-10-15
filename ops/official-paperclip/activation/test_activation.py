"""Behavioural fake-first tests. No live container, session, POST, or install."""
import copy
import ctypes
import fcntl
import json
import os
from pathlib import Path
import signal
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from common import code_hash, digest, encoded, process_token, publish, read_json, secure, sha
from continuation import resume
from executor import Executor, wait_clear, worker
from host import (Host, COMPOSE_ARGV, CANDIDATE, PREIMAGE, PRIVATE, CONFIG, COMPOSE,
                  OVERRIDE, MARKER, HTTP, CONFIG_TRANSFORM, APP_VERIFY, validate_plan)
from supervisor import Children, child_run, transaction


class Fake:
    def __init__(self):
        self.events = []
        self.clock = 100.0
        self.busy = [1, 0, 0]
        self.drift = False
        self.successor = False
        self.fail_verify = False
        self.posts = []
        self.status = ['running', 'completed']
        self.session = {'object': 'hermes.session', 'session': {'id': 'correct-existing-session', 'source': 'api_server'}}
        self.root = None
        self.fail_admission = False
        self.cas_calls = 0
        self.drift_at = None
        self.lock_probe = None

    def now(self):
        return self.clock

    def sleep(self, seconds):
        self.clock += seconds

    def snapshot(self):
        if self.lock_probe:
            self.lock_probe()
        if self.root:
            assert read_json(self.root / 'supervisor.json')['state'] == 'RUNNING'
        n = self.busy.pop(0) if self.busy else 0
        return dict(observed=self.clock, updated=self.clock, state='draining',
                    counters=dict(webui_runs=n, webui_streams=n, api_runs=n,
                                  background_api=n, completions=n, delegations=n, agents=n))

    def prerequisites(self):
        self.events.append('prerequisites')

    def admission(self):
        self.events.append('admission')
        if self.fail_admission:
            raise RuntimeError('BLOCKED_WEBUI_ADMISSION_ACCOUNTING')

    def marker(self, action, packet):
        self.events.append('marker:' + action)
        if action == 'create':
            return {'owned': {'dev': 1, 'ino': 2, 'sha': 'fake'}, 'stage': '.fake', 'requested': 99}
        if action == 'publish':
            assert read_json(self.root / 'marker.json') == packet
        return {}

    def marker_time(self, marker):
        return marker['requested']

    def cas(self, phase):
        if self.lock_probe:
            self.lock_probe()
        self.events.append('cas:' + phase)
        self.cas_calls += 1
        if self.drift or self.cas_calls == self.drift_at:
            raise RuntimeError('CAS_DRIFT')
        return {'identity': 'old' if not self.successor else 'new'}

    def config_bytes(self):
        return b'new-config'

    def write_config(self, content):
        self.events.append('config')

    def write_override(self):
        self.events.append('override')

    def recreate(self):
        self.events.append('recreate')
        self.successor = True

    def verify(self):
        self.events.append('verify')
        if self.fail_verify:
            raise RuntimeError('APPLICATION_NOT_VERIFIED')
        return {'application': 'verified', 'successor': 'new'}

    def memory_off(self, entry):
        assert entry == 'verified-external-memory-policy'

    def http(self, method, path, body=None, headers=None):
        self.events.append('http:' + method + ':' + path)
        if path == '/v1/capabilities':
            return {'features': {'run_submission': True, 'run_status': True,
                                 'runs_idempotency': {'supported': True, 'durable': True}}}
        if path.startswith('/api/sessions/'):
            return copy.deepcopy(self.session)
        if method == 'POST':
            assert path == '/v1/runs' and body['session_id'] == self.session['session']['id']
            self.posts.append((body, headers))
            return {'run_id': 'fake-run-123', 'status': 'started'}
        status = self.status.pop(0) if self.status else 'completed'
        return {'run_id': 'fake-run-123', 'session_id': self.session['session']['id'], 'status': status}


def fake_plan(b):
    return {'timeouts': dict(idle=10, drain=10, interval=1, child=10, continuation=10),
            'continuation': {'session': b.session['session']['id'], 'session_sha': digest(b.session),
                             'memory_off_evidence': 'verified-external-memory-policy'}}


class InProcessChildren:
    """Domain seam fake, not claimed evidence of host process survival."""
    def __init__(self, b):
        self.b = b
        self.prepared = None
        self.reaped = []

    def invoke(self, phase, root, binding, timeout):
        if self.b.lock_probe:
            self.b.lock_probe()
        e = Executor(self.b, binding['plan'], binding['code'], binding['run'])
        result = e.prepare() if phase == 'prepare' else e.activate(self.prepared)
        if phase == 'prepare':
            self.prepared = result
        self.reaped.append(phase)
        return {'binding': binding, 'result': result}


class RootCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=os.environ['TMPDIR'])
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.root.chmod(0o700)


class ExecutorTests(unittest.TestCase):
    def test_busy_then_two_fresh_clear_snapshots(self):
        b = Fake()
        samples = wait_clear(b, 10, 1)
        self.assertEqual([x['observed'] for x in samples], [101, 102])
        self.assertEqual(b.events, [])

    def test_all_counters_fail_closed(self):
        for key in Fake().snapshot()['counters']:
            for bad in (None, True, -1, 0.0, '0'):
                with self.subTest(key=key, bad=bad):
                    b = Fake(); s = b.snapshot(); s['counters'][key] = bad
                    b.snapshot = lambda: s
                    with self.assertRaisesRegex(RuntimeError, 'COUNTER_UNAVAILABLE'):
                        wait_clear(b, 10, 1)

    def test_missing_total_api_counter_is_not_idle(self):
        b = Fake(); sample = b.snapshot(); del sample['counters']['api_runs']
        b.snapshot = lambda: sample
        with self.assertRaisesRegex(RuntimeError, 'COUNTER_UNAVAILABLE'):
            wait_clear(b, 10, 1)

    def test_stale_and_duplicate_snapshots_fail(self):
        for stale in (True, False):
            b = Fake(); b.busy = [0]; s = b.snapshot()
            if stale:
                s['updated'] -= 6
            b.snapshot = lambda: s
            with self.assertRaisesRegex(RuntimeError, 'STALE_SNAPSHOT|SNAPSHOT_NOT_ADVANCING'):
                wait_clear(b, 10, 1)

    def test_drain_watcher_is_allowed_to_converge(self):
        b = Fake(); b.busy = [0, 0, 0]
        orig = b.snapshot
        def sample():
            s = orig()
            if b.now() == 100:
                s['state'] = 'running'
            return s
        b.snapshot = sample
        self.assertEqual(wait_clear(b, 10, 1, draining_since=99)[-1]['observed'], 102)

    def test_complete_executor_and_successor(self):
        b = Fake(); e = Executor(b, 'plan', 'code', 'run')
        activated = e.activate(e.prepare())
        self.assertEqual(activated['state'], 'VERIFIED')
        self.assertEqual(b.events, ['cas:pre', 'cas:pre', 'config', 'override', 'recreate', 'verify'])
        self.assertEqual(activated['result']['successor'], 'new')

    def test_prepare_cannot_be_rebound(self):
        b = Fake(); e = Executor(b, 'plan', 'code', 'run'); p = e.prepare()
        for key in ('run', 'code', 'plan', 'observed', 'config', 'state'):
            with self.subTest(key=key):
                bad = dict(p); bad[key] = 'foreign'
                with self.assertRaises(RuntimeError):
                    e.activate(bad)
        self.assertNotIn('config', b.events)

    def test_post_prepare_full_cas_failure_has_no_writes(self):
        b = Fake(); e = Executor(b, 'plan', 'code', 'run'); p = e.prepare(); b.drift = True
        with self.assertRaisesRegex(RuntimeError, 'CAS_DRIFT'):
            e.activate(p)
        self.assertNotIn('config', b.events)


class TransactionTests(RootCase):
    def run_tx(self, b):
        b.root = self.root
        return transaction(b, fake_plan(b), self.root, InProcessChildren(b),
                           {'plan': 'plan', 'code': 'code', 'run': self.root.name})

    def test_full_path_reaps_then_idempotent_callback_and_complete(self):
        b = Fake(); result = self.run_tx(b)
        self.assertEqual(result['state'], 'COMPLETED')
        self.assertEqual(b.events.count('recreate'), 1)
        self.assertEqual(len(b.posts), 1)
        self.assertLess(b.events.index('verify'), b.events.index('marker:clear'))
        self.assertLess(b.events.index('marker:clear'), b.events.index('http:POST:/v1/runs'))
        self.assertEqual(read_json(self.root / 'continuation.json')['state'], 'COMPLETED')

    def test_lock_covers_idle_prepare_and_activate(self):
        lock = self.root / 'sequence.lock'
        with lock.open('w') as f:
            lock.chmod(0o600); fcntl.flock(f, fcntl.LOCK_EX)
            def probe():
                with lock.open() as other:
                    with self.assertRaises(BlockingIOError):
                        fcntl.flock(other, fcntl.LOCK_EX | fcntl.LOCK_NB)
            b = Fake(); b.lock_probe = probe
            self.run_tx(b)

    def test_idle_timeout_does_not_publish_marker_or_invoke_executor(self):
        b = Fake(); b.busy = [1] * 100
        with self.assertRaisesRegex(RuntimeError, 'IDLE_TIMEOUT'):
            self.run_tx(b)
        self.assertNotIn('marker:create', b.events)
        self.assertNotIn('config', b.events)
        self.assertEqual(read_json(self.root / 'supervisor.json')['state'], 'BLOCKED_PRE_EFFECT')

    def test_missing_admission_blocks_before_marker(self):
        b = Fake(); b.fail_admission = True
        with self.assertRaisesRegex(RuntimeError, 'WEBUI_ADMISSION_ACCOUNTING'):
            self.run_tx(b)
        self.assertNotIn('marker:create', b.events)

    def test_cas_drift_after_drain_or_prepare_no_effect(self):
        for nth in (2, 4):
            with self.subTest(nth=nth):
                root = self.root / str(nth); root.mkdir(mode=0o700)
                b = Fake(); b.root = root; b.drift_at = nth
                with self.assertRaisesRegex(RuntimeError, 'CAS_DRIFT'):
                    transaction(b, fake_plan(b), root, InProcessChildren(b), {'plan':'p','code':'c','run':'r'})
                self.assertNotIn('config', b.events)
                self.assertNotIn('marker:clear', b.events)

    def test_post_recreate_failure_never_rolls_back_or_calls_continuation(self):
        b = Fake(); b.fail_verify = True
        with self.assertRaisesRegex(RuntimeError, 'APPLICATION_NOT_VERIFIED'):
            self.run_tx(b)
        self.assertEqual(b.events.count('recreate'), 1)
        self.assertEqual(b.posts, [])
        self.assertNotIn('marker:clear', b.events)
        self.assertEqual(read_json(self.root / 'supervisor.json')['state'], 'EFFECT_UNCERTAIN')

    def test_submitted_not_complete_and_resume_does_not_resubmit(self):
        b = Fake(); b.status = ['running'] * 100
        with self.assertRaisesRegex(RuntimeError, 'CONTINUATION_INCOMPLETE'):
            self.run_tx(b)
        self.assertEqual(read_json(self.root / 'supervisor.json')['state'], 'ACTIVATED_CONTINUATION_PENDING')
        self.assertEqual(read_json(self.root / 'continuation.json')['state'], 'SUBMITTED')
        b.status = ['completed']
        result = resume(b, fake_plan(b), self.root.name, self.root / 'continuation.json', children_reaped=True)
        self.assertEqual(result['state'], 'COMPLETED')
        self.assertEqual(len(b.posts), 1)
        self.assertEqual(b.events.count('recreate'), 1)

    def test_callback_wrong_session_no_post(self):
        b = Fake(); p = fake_plan(b); b.session['session']['source'] = 'webui'
        with self.assertRaisesRegex(RuntimeError, 'SESSION_BINDING'):
            resume(b, p, 'run', self.root / 'continuation.json', children_reaped=True)
        self.assertEqual(b.posts, [])

    def test_interruption_after_child_success_is_not_success_or_retry(self):
        b=Fake(); b.root=self.root
        class Interrupted(InProcessChildren):
            def invoke(child,phase,root,binding,timeout):
                result=super().invoke(phase,root,binding,timeout)
                publish(root/(phase+'.json'),result)
                if phase=='activate': raise KeyboardInterrupt()
                return result
        with self.assertRaises(KeyboardInterrupt):
            transaction(b,fake_plan(b),self.root,Interrupted(b),{'plan':'p','code':'c','run':'r'})
        self.assertEqual(read_json(self.root/'activate.json')['result']['state'],'VERIFIED')
        self.assertEqual(read_json(self.root/'supervisor.json')['state'],'EFFECT_UNCERTAIN')
        self.assertEqual(b.events.count('recreate'),1)
        self.assertEqual(b.posts,[])

    def test_second_interruption_during_continuation_only_resume(self):
        b=Fake(); b.status=['running']*100
        with self.assertRaisesRegex(RuntimeError,'CONTINUATION_INCOMPLETE'):
            self.run_tx(b)
        original=b.http
        def interrupt(method,path,body=None,headers=None):
            if path.startswith('/v1/runs/'): raise KeyboardInterrupt()
            return original(method,path,body,headers)
        b.http=interrupt
        with self.assertRaises(KeyboardInterrupt):
            resume(b,fake_plan(b),self.root.name,self.root/'continuation.json',children_reaped=True)
        self.assertEqual(read_json(self.root/'continuation.json')['state'],'SUBMITTED')
        self.assertEqual(len(b.posts),1)
        self.assertEqual(b.events.count('recreate'),1)

    def test_callback_requires_reaped_and_rejects_failed(self):
        b = Fake(); p = fake_plan(b)
        with self.assertRaisesRegex(RuntimeError, 'CHILD_NOT_REAPED'):
            resume(b, p, 'run', self.root / 'continuation.json', children_reaped=False)
        self.assertEqual(b.events, [])
        b.status = ['failed']
        with self.assertRaisesRegex(RuntimeError, 'CONTINUATION_FAILED'):
            resume(b, p, 'run', self.root / 'continuation.json', children_reaped=True)
        self.assertEqual(read_json(self.root / 'continuation.json')['state'], 'FAILED')


class TransportTests(RootCase):
    def test_secret_output_is_discarded_and_child_reaped(self):
        secret = 'fixture-sensitive-output-NEVER-PERSIST'
        result = child_run([sys.executable, '-c', 'import sys;print(%r);print(%r,file=sys.stderr)' % (secret,secret)],
                           self.root, 'probe', 10)
        self.assertTrue(result['reaped'])
        for f in self.root.iterdir():
            self.assertNotIn(secret.encode(), f.read_bytes())
        self.assertEqual(result['pgid'], result['pid'])
        with self.assertRaises(ProcessLookupError):
            os.kill(result['pid'], 0)

    def test_timeout_kills_group_and_reaps(self):
        self.assertEqual(ctypes.CDLL(None).prctl(36,1,0,0,0),0)
        script = ('import os,signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);'
                  'os.fork();time.sleep(20)')
        with self.assertRaisesRegex(RuntimeError, 'CHILD_TIMEOUT'):
            child_run([sys.executable, '-c', script], self.root, 'timeout', 0.1)
        r = read_json(self.root / 'timeout-process.json')
        self.assertEqual(r['state'], 'TIMEOUT')
        self.assertTrue(r['reaped'])
        self.assertEqual(r['rc'], -signal.SIGKILL)
        with self.assertRaises(ProcessLookupError):
            os.killpg(r['pgid'],0)

    def test_host_path_and_symlink_escape_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'ABSOLUTE_PATH'):
            secure('relative')
        link = self.root / 'link'; link.symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, 'SYMLINK'):
            secure(link, directory=True)
        for mode in (0o644, 0o666):
            f = self.root / ('bad'+str(mode)); f.write_text('{}'); f.chmod(mode)
            with self.assertRaisesRegex(RuntimeError, 'PATH_MODE|UNSAFE_ANCESTOR'):
                secure(f, 0o600, os.getuid())
        f = self.root / 'wrong-owner'; f.write_bytes(b'{}'); f.chmod(0o600)
        with self.assertRaisesRegex(RuntimeError, 'PATH_OWNER'):
            secure(f, 0o600, os.getuid()+1)

    def test_child_receipt_arbitrary_path_not_accepted(self):
        # Children chooses root/phase.json, never a caller-supplied receipt path.
        c = Children(self.root / 'plan.json', 123)
        def wrong_receipt(argv, root, phase, timeout, **kw):
            publish(root / (phase + '.json'), {'binding': {}, 'invocation': 'foreign', 'result': {}})
        with patch('supervisor.child_run', wrong_receipt):
            with self.assertRaisesRegex(RuntimeError, 'CHILD_RECEIPT_BINDING'):
                c.invoke('prepare', self.root, {'plan':'p','code':'c','run':'r'}, 10)

    def test_real_child_argv_is_fixed_and_receipt_bound(self):
        c = Children(self.root / 'plan.json', 123)
        binding = {'plan':'p','code':'c','run':'r'}
        def fake_child(argv, root, phase, timeout, **kw):
            self.assertEqual(argv[1], '-B')
            self.assertEqual(Path(argv[2]).name, 'executor.py')
            self.assertEqual(argv[3:6], [str(c.plan_path), str(root), 'prepare'])
            self.assertEqual(kw['pass_fds'], (123,))
            inv = read_json(root / 'prepare-invocation.json')
            self.assertEqual(argv[-1], digest(inv))
            publish(root / 'prepare.json', {'binding': binding, 'invocation': digest(inv),
                                            'result': dict(binding, state='PREPARED', observed='x',config='y')})
        with patch('supervisor.child_run', fake_child):
            self.assertEqual(c.invoke('prepare', self.root, binding, 10)['result']['state'], 'PREPARED')


class HostContractTests(unittest.TestCase):
    def test_compose_argv_no_build_pull_deps_and_only_moss(self):
        obj = object.__new__(Host)
        obj.p = {'files': {}}
        obj._render_pre = {'services': {'moss': {'image': 'old'}}}
        obj.source_check = lambda: None
        obj.render = lambda: {'services': {'moss': {'image': CANDIDATE}}}
        with patch('host.command', return_value=b'') as command:
            obj.recreate()
            self.assertEqual(command.call_args.args[0], COMPOSE_ARGV +
                             ['up','-d','--no-build','--no-deps','--pull','never','moss'])

    def test_native_shape_snapshot_keeps_total_api_counter(self):
        obj = object.__new__(Host)
        obj.http = lambda method,path,**kw: ({'status':'ok','active_runs':0,'active_streams':0} if kw else
                    {'status':'ok','updated_at':'1970-01-01T00:01:40+00:00','gateway_state':'draining',
                     'active_agents':0,'api_server':{'active_runs':2},
                     'readiness':{'checks':{'background_queues':{'active_api_runs':0,'process_completions':0,
                                                               'active_delegations':0}}}})
        obj.now = lambda: 100
        self.assertEqual(obj.snapshot()['counters']['api_runs'], 2)
        with self.assertRaisesRegex(RuntimeError, 'IDLE_TIMEOUT'):
            b = Fake(); b.snapshot = obj.snapshot; wait_clear(b, 1, 1)

    def test_live_backend_admission_gap_is_explicit_not_forged_protocol(self):
        obj = object.__new__(Host); obj.p = {'ingresses':['gateway','api','webui']}
        with self.assertRaisesRegex(RuntimeError, 'BLOCKED_WEBUI_ADMISSION_ACCOUNTING'):
            obj.admission()


def complete_plan():
    manifest = read_json(Path(__file__).parent / 'candidate.json')
    ident = dict(id='1'*64,image=PREIMAGE,started='2026-10-14T00:00:00Z',restarts=0,running=True)
    evidence = dict(path=str(PRIVATE/'inputs/external.json'),sha='a'*64,uid=0)
    names = ('common.py','executor.py','host.py','supervisor.py','continuation.py',
             'candidate.json','plan.schema.json','README.md','test_activation.py')
    transformer = '3cc5c8930ac6894dbad28969f8786f08566a0d9833afbf3e7fa5ee2120018a33'
    return dict(schema=1,scope='tac246-moss-only',host='MEDIA',code=code_hash(),
                source=dict(root=str(PRIVATE/'source'),commit='b'*40,tree='c'*40,uid=0,mode=0o700,
                            paths=sorted('ops/official-paperclip/activation/'+x for x in names)),
                files={k:dict(path=str(path),pre=transformer if k=='transformer' else 'd'*64,
                              post=transformer if k=='transformer' else 'd'*64,uid=0,mode=0o600)
                       for k,path in dict(config=CONFIG,compose=COMPOSE,override=OVERRIDE,
                                          transformer=PRIVATE/'inputs/configure.py').items()},
                preimage=ident,siblings={k:dict(identity=ident,invariants='e'*64) for k in ('denholm','jen','richmond')},
                render='f'*64,invariants='e'*64,installed=manifest['installed'],catalog=dict(count=44,sha='a'*64),
                continuation=dict(session='correct-existing-session',session_sha='a'*64,memory_off_evidence=evidence),
                adapter=evidence,timeouts=dict(idle=120,drain=120,child=240,interval=1,continuation=60),
                ingresses=['gateway','api','webui'])


class PlanTests(unittest.TestCase):
    def test_complete_synthetic_plan_is_accepted(self):
        self.assertEqual(validate_plan(complete_plan())['scope'], 'tac246-moss-only')

    def test_foreign_target_commands_transformer_and_old_session_rejected(self):
        mutations = [lambda p:p.update(scope='fleet'), lambda p:p.update(command=['rm','-rf','/']),
                     lambda p:p['files']['config'].update(path='/etc/passwd'),
                     lambda p:p['files']['transformer'].update(pre='a'*64,post='a'*64),
                     lambda p:p['continuation'].update(session='df6e86989771'),
                     lambda p:p.update(ingresses=['gateway','api']),
                     lambda p:p['source'].update(paths=['ops/official-paperclip/activation/host.py']),
                     lambda p:p['installed'].update({'gateway/platforms/api_server.py':'a'*64})]
        for mutation in mutations:
            p=complete_plan(); mutation(p)
            with self.subTest(mutation=mutation):
                with self.assertRaises(RuntimeError):
                    validate_plan(p)

    def test_embedded_remote_scripts_compile(self):
        for script in (MARKER,HTTP,CONFIG_TRANSFORM,APP_VERIFY):
            compile(script, '<fixed-remote-probe>', 'exec')

    def test_adapter_requires_loaded_producer_not_only_layer(self):
        obj=object.__new__(Host); obj.p=complete_plan()
        obj.external_evidence=lambda *a:dict(image='sha256:b9ad3a9483657cf25cc345310e1ad0801d926f6e43564c7aba06b5e8bdd416aa',
                                           reloaded=False,requestContextVerified=True,processStart='old-process')
        with self.assertRaisesRegex(RuntimeError,'ADAPTER_PRODUCER_NOT_ACTIVE'):
            obj.prerequisites()


class MarkerTests(RootCase):
    def marker(self, action, packet=None):
        prefix = ('import sys,types; m=types.ModuleType("gateway.drain_control");'
                  'm.current_instantiation_epoch=lambda:"fixture-epoch";'
                  'sys.modules["gateway.drain_control"]=m;\n')
        script = prefix + MARKER.replace("pathlib.Path('/opt/data/profiles/moss')", 'pathlib.Path('+repr(str(self.root))+')')
        p=subprocess.run([sys.executable,'-B','-c',script],input=encoded(dict(packet or {},action=action)),
                         stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,check=False)
        if p.returncode:
            raise RuntimeError('FIXTURE_MARKER_REFUSED')
        return json.loads(p.stdout)

    def test_native_marker_stage_ownership_before_publish_and_owned_clear(self):
        r=self.marker('create',{'run':'fixture-run'})
        self.assertFalse((self.root/'.drain_request.json').exists())
        self.assertTrue((self.root/r['stage']).exists())
        self.marker('publish',r)
        self.marker('check',r)
        self.marker('clear',r)
        self.assertFalse((self.root/'.drain_request.json').exists())

    def test_replaced_inode_or_bytes_cannot_be_cleared(self):
        r=self.marker('create',{'run':'fixture-run'}); self.marker('publish',r)
        target=self.root/'.drain_request.json'; raw=target.read_bytes()
        replacement=self.root/'replacement'; replacement.write_bytes(raw); os.replace(replacement,target)
        with self.assertRaisesRegex(RuntimeError,'FIXTURE_MARKER_REFUSED'):
            self.marker('clear',r)
        self.assertEqual(target.read_bytes(),raw)
        r['owned']['ino']=target.stat().st_ino
        target.write_bytes(b'{"action":"drain","principal":"foreign"}')
        with self.assertRaisesRegex(RuntimeError,'FIXTURE_MARKER_REFUSED'):
            self.marker('clear',r)
        self.assertTrue(target.exists())


class WorkerTests(RootCase):
    def test_prepare_activate_worker_receipts_bound_to_parent_plan_and_marker(self):
        runs=self.root/'runs'; runs.mkdir(mode=0o700)
        root=runs/'fixture-run'; root.mkdir(mode=0o700)
        lock=runs/'sequence.lock'; lock.write_text(''); lock.chmod(0o600)
        p=complete_plan(); plan_path=self.root/'plan.json'; publish(plan_path,p)
        b=Fake(); b.root=None
        binding=dict(plan=digest(p),code=code_hash(),run=root.name)
        publish(root/'marker.json',{'requested':99,'owned':{}})
        parent=dict(pid=os.getppid(),start=process_token(os.getppid()))
        with lock.open('r+') as f, patch('executor.Host',return_value=b):
            fcntl.flock(f,fcntl.LOCK_EX)
            inv=dict(binding=binding,phase='prepare',nonce='fixture-nonce',parent=parent)
            publish(root/'prepare-invocation.json',inv)
            worker(plan_path,root,'prepare',f.fileno(),digest(inv))
            receipt=read_json(root/'prepare.json')
            self.assertEqual(receipt['invocation'],digest(inv))
            inv=dict(binding=binding,phase='activate',nonce='fixture-nonce-2',parent=parent,
                     prepared=digest(receipt))
            publish(root/'activate-invocation.json',inv)
            worker(plan_path,root,'activate',f.fileno(),digest(inv))
        self.assertEqual(read_json(root/'activate.json')['result']['state'],'VERIFIED')
        self.assertEqual(b.events.count('recreate'),1)


class ApplicationProbeTests(RootCase):
    def test_complete_fake_sdk_and_rejects_static_context_bridge_or_old_bytes(self):
        names=['paperclipMe']+['fixtureTool%02d'%i for i in range(43)]
        catalog=dict(count=44,sha=digest(sorted(names)))
        (self.root/'config.yaml').write_text('{}')
        (self.root/'installed.py').write_text('# fixture installed bytes\n')
        installed={'installed.py':sha((self.root/'installed.py').read_bytes())}
        legacy=['paperclip_access','paperclip-access','tac_paperclip_callback','tac-paperclip-callback','denholm_ceo','denholm-ceo']
        cfg={'mcp_servers':{'paperclip':{'command':'/opt/paperclip-mcp/node_modules/.bin/paperclip-mcp-server',
             'args':[],'env':{'PAPERCLIP_AGENT_ID':'541d5e6d-2ba6-42ee-81b0-a5ab2d892a10',
                              'PAPERCLIP_COMPANY_ID':'9d914ba2-725e-4006-81f8-bc6f1eb1f411',
                              'PAPERCLIP_RUN_CONTEXT_MODE':'request'}}},
             'plugins':{'enabled':[],'disabled':legacy},'platform_toolsets':{'api_server':['paperclip']}}
        prefix='''
import sys,types,os
from contextlib import asynccontextmanager
N=types.SimpleNamespace
yaml=types.ModuleType('yaml'); yaml.safe_load=lambda raw:CONFIG; sys.modules['yaml']=yaml
mcp=types.ModuleType('mcp'); client=types.ModuleType('mcp.client'); stdio=types.ModuleType('mcp.client.stdio')
class Session:
 def __init__(self,*a): pass
 async def __aenter__(self): return self
 async def __aexit__(self,*a): pass
 async def initialize(self): return N(serverInfo=N(name='paperclip'))
 async def list_tools(self,**kw): return N(tools=[N(name=x) for x in NAMES],nextCursor=None)
 async def call_tool(self,name,args):
  assert name=='paperclipMe' and args=={}
  return N(isError=True,error='Missing paperclip/run-context')
@asynccontextmanager
async def stdio_client(*a,**kw): yield (None,None)
mcp.ClientSession=Session; mcp.StdioServerParameters=lambda **kw:kw; stdio.stdio_client=stdio_client
sys.modules.update({'mcp':mcp,'mcp.client':client,'mcp.client.stdio':stdio})
'''
        script=APP_VERIFY.replace("pathlib.Path('/opt/data/profiles/moss')",'pathlib.Path('+repr(str(self.root))+')')
        script=script.replace("pathlib.Path('/opt/hermes')",'pathlib.Path('+repr(str(self.root))+')')
        for variant in ('good','static-context','bridge','old-bytes'):
            c=copy.deepcopy(cfg); ins=dict(installed)
            if variant=='static-context': c['mcp_servers']['paperclip']['env']['PAPERCLIP_RUN_ID']='stale'
            if variant=='bridge': c['plugins']['enabled']=['paperclip_access']
            if variant=='old-bytes': ins['installed.py']='a'*64
            source='CONFIG='+repr(c)+'\nNAMES='+repr(names)+'\n'+prefix+'\nos.environ["HERMES_HOME"]='+repr(str(self.root))+'\n'+script
            result=subprocess.run([sys.executable,'-B','-c',source],input=encoded(dict(installed=ins,catalog=catalog)),
                                  stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=10)
            with self.subTest(variant=variant):
                if variant=='good':
                    self.assertEqual(result.returncode,0)
                    self.assertEqual(json.loads(result.stdout),dict(bytes=True,context=True,bridgeInactive=True,catalog=True))
                else:
                    self.assertNotEqual(result.returncode,0)


class MutationTests(RootCase):
    def test_causal_mutants_fail_at_named_behaviour_oracle(self):
        cases=[('executor.py','if len(clear) == 2:','if len(clear) == 1:',
                'ExecutorTests.test_busy_then_two_fresh_clear_snapshots'),
               ('executor.py',"observed = self.b.cas('pre')\n        content = self.b.config_bytes()\n        need(prepared",
                "observed = {'identity':'old'}\n        content = self.b.config_bytes()\n        need(prepared",
                'ExecutorTests.test_post_prepare_full_cas_failure_has_no_writes'),
               ('host.py',"'api_runs': d['api_server']['active_runs']","'api_runs': q['active_api_runs']",
                'HostContractTests.test_native_shape_snapshot_keeps_total_api_counter'),
               ('continuation.py',"need(children_reaped is True, 'CHILD_NOT_REAPED')",
                "need(True, 'CHILD_NOT_REAPED')",'TransactionTests.test_callback_requires_reaped_and_rejects_failed')]
        source=Path(__file__).parent
        for i,(name,before,after,target) in enumerate(cases):
            with self.subTest(mutant=i,oracle=target):
                dest=self.root/str(i); dest.mkdir(mode=0o700)
                for p in source.iterdir():
                    if p.is_file(): shutil.copyfile(p,dest/p.name)
                p=dest/name; raw=p.read_text(); self.assertEqual(raw.count(before),1)
                p.write_text(raw.replace(before,after))
                proc=subprocess.run([sys.executable,'-B','-m','unittest','test_activation.'+target],
                                    cwd=dest,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=30)
                self.assertNotEqual(proc.returncode,0)
                self.assertIn(b'FAIL:',proc.stdout)
                self.assertIn(target.split('.')[-1].encode(),proc.stdout)


if __name__ == '__main__':
    unittest.main()
