"""External finite host supervisor and separate exact-byte executor child.
No launcher installation, daemonization, scheduling, rollback, or retry of effects.
"""
import argparse
import ctypes
import fcntl
import json
import os
from pathlib import Path
import secrets
import signal
import subprocess
import sys
import time

from common import (ENV, code_hash, digest, encoded, error_code, need, process_token, publish,
                    read_json, reap_group, secure)
from continuation import resume
from executor import wait_clear
from host import Host, PRIVATE


def child_run(argv, root, phase, timeout, *, pass_fds=()):
    # No raw stdout/stderr, even on errors. Child's structured receipt is the channel.
    p = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True,
                         env=ENV, pass_fds=pass_fds)
    evidence = dict(pid=p.pid, pgid=p.pid, argv=digest(argv), started=time.time(), state='RUNNING')
    try:
        evidence['start'] = process_token(p.pid)
        publish(root / (phase + '-process.json'), evidence, exclusive=True)
        try:
            rc = p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            evidence['state'] = 'TIMEOUT'
            raise RuntimeError('CHILD_TIMEOUT') from None
        need(rc == 0, 'CHILD_FAILED')
        evidence['state'] = 'EXITED'
    finally:
        try:
            reap_group(p)
        except BaseException:
            evidence.update(state='CLEANUP_FAILED', reaped=False, rc=p.returncode, ended=time.time())
            publish(root / (phase + '-process.json'), evidence)
            raise
        evidence.update(reaped=True, rc=p.returncode, ended=time.time())
        publish(root / (phase + '-process.json'), evidence)
    return evidence


class Children:
    def __init__(self, plan_path, lock_fd):
        self.plan_path = plan_path
        self.lock_fd = lock_fd

    def invoke(self, phase, root, binding, timeout):
        invocation = {'binding': binding, 'phase': phase, 'nonce': secrets.token_hex(32),
                      'parent': {'pid': os.getpid(), 'start': process_token(os.getpid())}}
        if phase == 'activate':
            invocation['prepared'] = digest(read_json(root / 'prepare.json'))
        publish(root / (phase + '-invocation.json'), invocation, exclusive=True)
        argv = [sys.executable, '-B', str(Path(__file__).resolve().with_name('executor.py')),
                str(self.plan_path), str(root), phase, str(self.lock_fd), digest(invocation)]
        child_run(argv, root, phase, timeout, pass_fds=(self.lock_fd,))
        receipt = secure(root / (phase + '.json'), 0o600, os.getuid())
        response = read_json(receipt)
        need(response['invocation'] == digest(invocation) and response['binding'] == binding,
             'CHILD_RECEIPT_BINDING')
        expected = {'invocation', 'binding', 'result'}
        need(set(response) == expected, 'CHILD_RECEIPT_SCHEMA')
        if phase == 'prepare':
            need(set(response['result']) == {'plan','code','run','state','observed','config'} and
                 response['result']['state'] == 'PREPARED' and
                 all(response['result'][k] == v for k,v in binding.items()), 'PREPARE_RECEIPT')
        else:
            need(set(response['result']) == {'plan','code','run','state','result'} and
                 response['result']['state'] == 'VERIFIED' and
                 all(response['result'][k] == v for k,v in binding.items()), 'ACTIVATE_RECEIPT')
        return response


def transaction(backend, plan, root, children, binding):
    """Caller holds the durable sequence lock throughout this entire function."""
    state = dict(binding=binding, phase='WAIT_IDLE', state='RUNNING', started=backend.now())
    terminal = root / 'supervisor.json'
    publish(terminal, state, exclusive=True)  # BEFORE waiting or any marker.
    marker = None
    effect_intent = False
    effect_verified = False
    try:
        backend.prerequisites()
        backend.cas('pre')
        backend.admission()  # Missing coverage is a precise pre-marker gate, not six zeros.
        wait_clear(backend, plan['timeouts']['idle'], plan['timeouts']['interval'])
        state['phase'] = 'DRAIN'; publish(terminal, state)
        marker = backend.marker('create', {'run': binding['run']})
        publish(root / 'marker.json', marker, exclusive=True)  # ownership BEFORE publish
        backend.marker('publish', marker)
        wait_clear(backend, plan['timeouts']['drain'], plan['timeouts']['interval'],
                   draining_since=backend.marker_time(marker))
        backend.marker('check', marker)
        backend.cas('pre')  # Full post-drain CAS, not only old container identity.
        state['phase'] = 'PREPARE'; publish(terminal, state)
        prepared = children.invoke('prepare', root, binding, plan['timeouts']['child'])
        need(prepared['binding'] == binding, 'PREPARE_BINDING')
        backend.marker('check', marker)
        backend.cas('pre')  # Includes on-disk source after prepare.
        state['phase'] = 'EFFECT_INTENT'; publish(terminal, state)
        effect_intent = True  # Any subsequent error is uncertain; never auto-reapply/rollback.
        activated = children.invoke('activate', root, binding, plan['timeouts']['child'])
        need(activated['binding'] == binding, 'ACTIVATE_BINDING')
        effect_verified = True
        state['phase'] = 'CHILD_REAPED'; publish(terminal, state)
        # Clear only exact owned inode/hash, including after successor recreation.
        backend.marker('clear', marker)
        state['phase'] = 'CONTINUATION'; publish(terminal, state)
        result = resume(backend, plan, binding['run'], root / 'continuation.json', children_reaped=True)
        state.update(phase='TERMINAL', state='COMPLETED', continuation=digest(result),
                     activated=digest(activated))
    except BaseException as exc:
        state['gate'] = error_code(exc)
        state.update(state=('ACTIVATED_CONTINUATION_PENDING' if effect_verified else
                            'EFFECT_UNCERTAIN' if effect_intent else 'BLOCKED_PRE_EFFECT'))
        # Fail closed, leave marker custody for explicit human reconciliation.
        # Never a blind clear, file restore, lifecycle retry, or automatic rollback.
        raise
    finally:
        state['ended'] = backend.now()
        publish(terminal, state)
    return state


def launch(plan_path):
    need(os.uname().nodename.upper() == 'MEDIA', 'HOST_IDENTITY')
    plan_path = secure(plan_path, 0o600, os.getuid())
    need(plan_path.parent == PRIVATE, 'PLAN_LOCATION')
    p = read_json(plan_path)
    need(code_hash() == p['code'], 'PACKAGE_CAS')
    secure(Path(__file__).parent, 0o700, os.getuid(), True)
    need(Path(__file__).parent == PRIVATE / 'package', 'PACKAGE_LOCATION')
    for name in ('common.py','executor.py','host.py','supervisor.py','continuation.py',
                 'candidate.json','plan.schema.json'):
        secure(Path(__file__).parent / name, 0o600, os.getuid())
    # Subreaper: adopted descendants are reaped by child_run/reap_group.
    need(ctypes.CDLL(None).prctl(36, 1, 0, 0, 0) == 0, 'SUBREAPER_UNAVAILABLE')
    def interrupted(signum, frame):
        raise RuntimeError('SUPERVISOR_INTERRUPTED')
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    runs = secure(PRIVATE / 'runs', 0o700, os.getuid(), True)
    lock_path = runs / 'sequence.lock'
    if not lock_path.exists():
        fd = os.open(lock_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
        os.fsync(fd); os.close(fd)
    secure(lock_path, 0o600, os.getuid())
    fd = os.open(lock_path, os.O_RDWR | os.O_NOFOLLOW)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        run = secrets.token_hex(16)
        root = runs / run
        root.mkdir(mode=0o700)
        directory_fd = os.open(runs, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
        binding = dict(run=run, plan=digest(p), code=code_hash())
        publish(root / 'launcher.json', dict(binding=binding, pid=os.getpid(), pgid=os.getpgrp(),
                                            start=process_token(os.getpid()), created=time.time()), exclusive=True)
        return transaction(Host(p), p, root, Children(plan_path, fd), binding)
    finally:
        os.close(fd)


def main():
    try:

        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument('--preflight', action='store_true', help='read-only; no lock/receipt/drain')
        parser.add_argument('plan', type=Path)
        args = parser.parse_args()
        if args.preflight:
            need(os.uname().nodename.upper() == 'MEDIA' and args.plan.parent == PRIVATE, 'HOST_IDENTITY')
            p = read_json(secure(args.plan, 0o600, os.getuid()))
            need(code_hash() == p['code'], 'PACKAGE_CAS')
            b = Host(p); b.prerequisites(); b.cas('pre'); b.snapshot(); b.admission()
            print('{"state":"PREFLIGHT_PASSED_NO_EFFECTS"}')
            return 0
        result = launch(args.plan)
        print(json.dumps({'state': result['state'], 'receipt': digest(result)}))
        return 0
    except BaseException as exc:
        # No tracebacks/exception messages: they may contain credentials or raw responses.
        print(json.dumps({'state': 'FAILED_RECONCILE_RECEIPTS', 'gate': error_code(exc)}))
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
