"""Bounded private host I/O. Never persist command output or exception text."""
import hashlib
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import tempfile
import time

ENV = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': '/root', 'LANG': 'C.UTF-8',
       'DOCKER_HOST': 'unix:///var/run/docker.sock', 'PYTHONDONTWRITEBYTECODE': '1',
       'GIT_OPTIONAL_LOCKS': '0'}


def need(ok, code):
    if not ok:
        raise RuntimeError(code)


def error_code(exc):
    allowed = {'BLOCKED_WEBUI_ADMISSION_ACCOUNTING', 'ADAPTER_PRODUCER_NOT_ACTIVE',
               'CONTINUATION_SESSION_INPUT', 'CONTINUATION_SESSION_BINDING', 'API_CAPABILITIES',
               'MEMORY_OFF_UNPROVEN', 'EVIDENCE_NOT_VERIFIED', 'EVIDENCE_CAS', 'IDLE_TIMEOUT',
               'CHILD_TIMEOUT', 'CONTINUATION_FAILED', 'CONTINUATION_INCOMPLETE',
               'COUNTER_UNAVAILABLE', 'STALE_SNAPSHOT', 'SOURCE_DIRTY', 'PACKAGE_CAS'}
    value = exc.args[0] if type(exc) is RuntimeError and exc.args else None
    return value if isinstance(value, str) and value in allowed else 'FAILED_RECONCILE_RECEIPTS'


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def encoded(obj):
    return json.dumps(obj, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()


def digest(obj):
    return sha(encoded(obj))


def secure(path, mode=None, uid=None, directory=False):
    p = Path(path)
    need(p.is_absolute() and '..' not in p.parts, 'ABSOLUTE_PATH_REQUIRED')
    for ancestor in (*reversed(p.parents), p):
        s = ancestor.lstat()
        need(not stat.S_ISLNK(s.st_mode), 'SYMLINK_REJECTED')
        need(not s.st_mode & 0o022, 'UNSAFE_ANCESTOR')
    s = p.lstat()
    need((stat.S_ISDIR(s.st_mode) if directory else stat.S_ISREG(s.st_mode)), 'PATH_TYPE')
    need(uid is None or s.st_uid == uid, 'PATH_OWNER')
    need(mode is None or stat.S_IMODE(s.st_mode) == mode, 'PATH_MODE')
    return p


def read_json(path):
    return json.loads(Path(path).read_bytes())


def publish(path, obj, exclusive=False):
    p = Path(path)
    secure(p.parent, 0o700, os.getuid(), True)
    if p.exists() or p.is_symlink():
        secure(p, 0o600, os.getuid())
    fd, name = tempfile.mkstemp(prefix='.receipt-', dir=p.parent)
    try:
        with os.fdopen(fd, 'wb') as f:
            os.fchmod(f.fileno(), 0o600)
            f.write(encoded(obj)); f.flush(); os.fsync(f.fileno())
        if exclusive:
            os.link(name, p)
        else:
            os.replace(name, p)
        d = os.open(p.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(d)
        finally:
            os.close(d)
    finally:
        os.unlink(name) if os.path.exists(name) else None


def process_token(pid):
    return Path('/proc/%d/stat' % pid).read_text().rsplit(')', 1)[1].split()[19]


def reap_group(p, grace=2):
    # A successful leader may leave children holding inherited lock descriptors.
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(p.pid, sig)
        except ProcessLookupError:
            pass
        try:
            p.wait(timeout=grace)
        except subprocess.TimeoutExpired:
            continue
        if sig == signal.SIGTERM:
            time.sleep(min(grace, 0.05))
    p.wait(timeout=grace)
    # Reap adopted grandchildren when running as Linux subreaper.
    until = time.monotonic() + grace
    while time.monotonic() < until:
        try:
            child, _ = os.waitpid(-p.pid, os.WNOHANG)
        except ChildProcessError:
            break
        if child == 0:
            time.sleep(0.01)
    try:
        os.killpg(p.pid, 0)
    except ProcessLookupError:
        return
    raise RuntimeError('CHILD_GROUP_SURVIVED')


def command(argv, timeout=30, raw=None):
    # Probe output is kept only in memory. Effect output goes to /dev/null.
    p = subprocess.Popen(argv, stdin=subprocess.PIPE if raw is not None else subprocess.DEVNULL,
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                         env=ENV, start_new_session=True)
    try:
        out, _ = p.communicate(raw, timeout=timeout)
        need(p.returncode == 0, 'COMMAND_FAILED')
        need(len(out) <= 16 * 1024 * 1024, 'OUTPUT_TOO_LARGE')
        return out
    except subprocess.TimeoutExpired:
        raise RuntimeError('COMMAND_TIMEOUT') from None
    finally:
        reap_group(p)


def code_hash():
    root = Path(__file__).resolve().parent
    return digest({n: sha((root / n).read_bytes()) for n in
                   ('common.py', 'executor.py', 'host.py', 'supervisor.py', 'continuation.py',
                    'candidate.json', 'plan.schema.json')})
