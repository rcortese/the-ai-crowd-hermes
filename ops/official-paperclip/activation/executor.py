"""Moss-only ordered effects; no lifecycle rollback, migration or retry."""
import ctypes
import os
from pathlib import Path
import sys
from common import code_hash, digest, need, process_token, publish, read_json, secure, sha
from host import Host

COUNTERS = frozenset(('webui_runs', 'webui_streams', 'api_runs', 'background_api',
                      'completions', 'delegations', 'agents'))


def wait_clear(backend, timeout, interval, *, draining_since=None):
    deadline = backend.now() + timeout
    clear = []
    while backend.now() <= deadline:
        s = backend.snapshot()
        counts = s.get('counters', {})
        need(set(counts) == COUNTERS and all(type(n) is int and n >= 0 for n in counts.values()),
             'COUNTER_UNAVAILABLE')
        now = backend.now()
        need(0 <= now - s['observed'] <= 5 and 0 <= now - s['updated'] <= 5,
             'STALE_SNAPSHOT')
        if draining_since is not None and (s['state'] != 'draining' or s['updated'] <= draining_since):
            clear = []
            backend.sleep(interval)
            continue
        if not any(counts.values()):
            if clear:
                need(s['observed'] > clear[-1]['observed'] and s['updated'] > clear[-1]['updated'],
                     'SNAPSHOT_NOT_ADVANCING')
            clear.append(s)
            if len(clear) == 2:
                return clear
        else:
            clear = []
        backend.sleep(interval)
    raise RuntimeError('IDLE_TIMEOUT')


class Executor:
    def __init__(self, backend, plan_hash, code_hash, run):
        self.b = backend
        self.binding = dict(plan=plan_hash, code=code_hash, run=run)

    def prepare(self):
        observed = self.b.cas('pre')
        content = self.b.config_bytes()
        return dict(self.binding, state='PREPARED', observed=digest(observed), config=sha(content))

    def activate(self, prepared):
        need(set(prepared) == {'plan', 'code', 'run', 'state', 'observed', 'config'} and
             all(prepared[k] == v for k, v in self.binding.items()) and
             prepared['state'] == 'PREPARED', 'PREPARE_BINDING')
        # Full source/package/config/render/container CAS again after prepare.
        observed = self.b.cas('pre')
        content = self.b.config_bytes()
        need(prepared['observed'] == digest(observed) and prepared['config'] == sha(content),
             'PREPARE_CAS')
        self.b.write_config(content)
        self.b.write_override()
        # The caller durably records EFFECT_INTENT before entering this method.
        self.b.recreate()
        result = self.b.verify()
        return dict(self.binding, state='VERIFIED', result=result)


def worker(plan_path, root, phase, lock_fd, invocation_hash):
    need(phase in ('prepare', 'activate'), 'CHILD_PHASE')
    plan = read_json(secure(plan_path, 0o600, os.getuid()))
    secure(root, 0o700, os.getuid(), True)
    invocation = read_json(secure(root / (phase + '-invocation.json'), 0o600, os.getuid()))
    need(digest(invocation) == invocation_hash and invocation['phase'] == phase, 'INVOCATION_CAS')
    parent = invocation['parent']
    need(os.getppid() == parent['pid'] and process_token(parent['pid']) == parent['start'], 'PARENT_CAS')
    lock = secure(root.parent / 'sequence.lock', 0o600, os.getuid()).stat()
    fdstat = os.fstat(lock_fd)
    need((fdstat.st_dev, fdstat.st_ino) == (lock.st_dev, lock.st_ino), 'LOCK_DESCRIPTOR')
    b = Host(plan)
    binding = invocation['binding']
    need(binding['plan'] == digest(plan) and binding['code'] == code_hash() == plan['code'] and
         binding['run'] == root.name, 'PACKAGE_CAS')
    b.prerequisites()
    marker = read_json(secure(root / 'marker.json', 0o600, os.getuid()))
    b.marker('check', marker)
    executor = Executor(b, binding['plan'], binding['code'], binding['run'])
    if phase == 'prepare':
        result = executor.prepare()
    else:
        prepared = read_json(secure(root / 'prepare.json', 0o600, os.getuid()))
        need(digest(prepared) == invocation['prepared'] and prepared['binding'] == binding,
             'PREPARE_RECEIPT_CAS')
        wait_clear(b, plan['timeouts']['drain'], plan['timeouts']['interval'],
                   draining_since=b.marker_time(marker))
        b.marker('check', marker)
        result = executor.activate(prepared['result'])
    publish(root / (phase + '.json'), dict(invocation=invocation_hash, binding=binding, result=result),
            exclusive=True)


if __name__ == '__main__':
    try:
        need(len(sys.argv) == 6, 'EXECUTOR_ARGUMENTS')
        need(ctypes.CDLL(None).prctl(36, 1, 0, 0, 0) == 0, 'SUBREAPER_UNAVAILABLE')
        worker(Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], int(sys.argv[4]), sys.argv[5])
    except BaseException:
        raise SystemExit(2) from None
