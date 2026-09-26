#!/usr/bin/env python3
"""Host-side Git+Compose CAS for a single canonical Moss image release.

Called only by the host supervisor after operator approval. Never imports user
runtime data; preserves the unrelated dirty persona image line verbatim.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path('/mnt/ssd/appdata/the-ai-crowd')
HERE = Path(__file__).resolve().parent
GIT = ('git', '-c', f'safe.directory={ROOT}', '-C', str(ROOT))
OLD = 'de1afd1e65541ef7b358f86ef5ce488399b86937'
MANIFEST = json.loads((HERE / 'release.json').read_text())
NEW = MANIFEST['commit']
BUNDLE = HERE / 'release.bundle'
BUNDLE_SHA = MANIFEST['bundle_sha256']
COMPOSE_SHA = 'd06cc789f262260598f44341f2e1de5f6b413c6d722b7382a403c70a5e0fa95f'
BASE_IMAGE = 'sha256:05838ef5c373b913f4a0652ca76f4f0ca827c6a18754b2616a39a6d02a9df005'
NEXT_IMAGE = 'sha256:14a0a1930c386a9342efae4db712d3dcd39a9c4298709dcc3e0b39863a612f30'
RECEIPT = HERE / 'source-receipt.json'
BACKUP_COMPOSE = HERE / 'compose.preimage'
BACKUP_INDEX = HERE / 'index.preimage'
COMPOSE = ROOT / 'compose.yaml'
INDEX = ROOT / '.git/index'


def call(*argv, text=True):
    return subprocess.check_output(argv, text=text, cwd=ROOT).strip() if text else subprocess.check_output(argv, cwd=ROOT)


def git(*argv, text=True):
    return call(*GIT, *argv, text=text)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def receipt(state, **extra):
    payload = dict(state=state, old=OLD, new=NEW, **extra)
    tmp = RECEIPT.with_suffix('.json.next')
    tmp.write_text(json.dumps(payload, sort_keys=True) + '\n')
    os.replace(tmp, RECEIPT)


def new_files() -> list[str]:
    changed = str(git('diff-tree', '--no-commit-id', '--name-only', '-r', OLD, NEW)).splitlines()
    expected = ['compose.yaml'] + [f'ops/inline-delegation/{path.name}' for path in HERE.iterdir()
                                   if path.is_file() and path.name not in
                                   ('release.json', 'release.bundle', 'source-receipt.json',
                                    'compose.preimage', 'index.preimage', 'activation.log',
                                    'activation.state', 'activation.lock', 'launcher.pid',
                                    'launcher.state', 'moss-inline-52a1903.bundle')]
    if sorted(changed) != sorted(expected):
        raise RuntimeError('candidate path closure drift')
    return [name for name in changed if name != 'compose.yaml']


def check():
    if sha(BUNDLE.read_bytes()) != BUNDLE_SHA or sha(COMPOSE.read_bytes()) != COMPOSE_SHA:
        raise RuntimeError('source/bundle drift')
    if git('rev-parse', 'HEAD') != OLD or git('status', '--porcelain', '--untracked-files=no') != ' M compose.yaml':
        raise RuntimeError('host source custody drift')
    if git('cat-file', '-t', NEW) != 'commit' or git('merge-base', OLD, NEW) != OLD:
        raise RuntimeError('candidate object unavailable or divergent')
    for name in new_files():
        if (ROOT / str(name)).exists() or (HERE / Path(str(name)).name).read_bytes() != git('show', f'{NEW}:{name}', text=False):
            raise RuntimeError(f'candidate file collision or transport drift: {name}')
    if sha(COMPOSE.read_bytes()) != COMPOSE_SHA or COMPOSE.read_bytes().count(BASE_IMAGE.encode()) != 1:
        raise RuntimeError('compose image anchor drift')
    print('SOURCE_CHECK_READY')


def atomic_write(path, data, mode=0o644):
    tmp = path.with_name(path.name + '.inline-next')
    with open(tmp, 'xb') as out:
        out.write(data)
        out.flush()
        os.fsync(out.fileno())
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def prepare():
    if any(p.exists() for p in (RECEIPT, BACKUP_COMPOSE, BACKUP_INDEX)):
        raise RuntimeError('existing source transaction requires reconciliation')
    if sha(BUNDLE.read_bytes()) != BUNDLE_SHA or sha(COMPOSE.read_bytes()) != COMPOSE_SHA:
        raise RuntimeError('source preimage drift')
    if git('rev-parse', 'HEAD') != OLD or git('symbolic-ref', '--short', 'HEAD') != 'main':
        raise RuntimeError('source HEAD drift')
    if git('status', '--porcelain', '--untracked-files=no') != ' M compose.yaml':
        raise RuntimeError('index/worktree custody drift')
    if git('ls-remote', 'origin', 'refs/heads/main').split()[0] != OLD:
        raise RuntimeError('remote main drift')
    git('bundle', 'verify', str(BUNDLE))
    git('fetch', '--no-tags', str(BUNDLE), 'refs/heads/release/moss-inline-http-delegation')
    if git('rev-parse', 'FETCH_HEAD') != NEW or git('merge-base', OLD, NEW) != OLD:
        raise RuntimeError('candidate ancestry drift')
    paths = new_files()
    for name in paths:
        if (ROOT / name).exists():
            raise RuntimeError(f'path collision {name}')
    original = COMPOSE.read_bytes()
    if original.count(BASE_IMAGE.encode()) != 1:
        raise RuntimeError('Moss image anchor drift')
    intended = original.replace(BASE_IMAGE.encode(), NEXT_IMAGE.encode())
    # A durable backup precedes any ref, index, or working-tree change.
    atomic_write(BACKUP_COMPOSE, original, 0o600)
    atomic_write(BACKUP_INDEX, INDEX.read_bytes(), 0o600)
    receipt('BACKED_UP', compose_sha=sha(original), index_sha=sha(BACKUP_INDEX.read_bytes()))
    if sha(COMPOSE.read_bytes()) != COMPOSE_SHA or git('rev-parse', 'HEAD') != OLD:
        raise RuntimeError('source changed after backup')
    # Index and worktree are transitioned under the host-wide activation lock.
    for name in paths:
        path = ROOT / name
        path.parent.mkdir(parents=True, exist_ok=True)
        atomic_write(path, git('show', f'{NEW}:{name}', text=False))
    atomic_write(COMPOSE, intended)
    receipt('FILES_MATERIALIZED')
    git('read-tree', NEW)
    git('update-ref', 'refs/heads/main', NEW, OLD)
    receipt('SOURCE_LOCAL', compose_sha=sha(intended))
    if git('status', '--porcelain', '--untracked-files=no') != ' M compose.yaml':
        raise RuntimeError('unexpected tracked residue after local source promotion')
    if NEXT_IMAGE not in COMPOSE.read_text():
        raise RuntimeError('candidate not selected by host Compose')
    print('SOURCE_LOCAL ' + NEW)


def rollback():
    if not RECEIPT.exists() or not BACKUP_COMPOSE.exists() or not BACKUP_INDEX.exists():
        raise RuntimeError('missing source recovery artifact')
    current = json.loads(RECEIPT.read_text())
    if current['state'] == 'SOURCE_PUBLISHED':
        raise RuntimeError('published source needs a new revert commit, not ref rewind')
    head = git('rev-parse', 'HEAD')
    if head not in (OLD, NEW):
        raise RuntimeError('source HEAD changed; manual reconciliation required')
    original = BACKUP_COMPOSE.read_bytes()
    intended = original.replace(BASE_IMAGE.encode(), NEXT_IMAGE.encode())
    if COMPOSE.read_bytes() not in (original, intended):
        raise RuntimeError('compose bytes changed; manual reconciliation required')
    if head == NEW:
        git('update-ref', 'refs/heads/main', OLD, NEW)
    # Restore only bytes belonging to this transaction. Do not clean unrelated staging.
    for name in new_files():
        path = ROOT / name
        expected = git('show', f'{NEW}:{name}', text=False)
        if path.exists():
            if path.read_bytes() != expected:
                raise RuntimeError(f'source path changed: {name}')
            path.unlink()
    atomic_write(COMPOSE, original)
    atomic_write(INDEX, BACKUP_INDEX.read_bytes(), 0o644)
    receipt('SOURCE_ROLLED_BACK')
    if git('rev-parse', 'HEAD') != OLD or sha(COMPOSE.read_bytes()) != COMPOSE_SHA:
        raise RuntimeError('source rollback failed')
    print('SOURCE_ROLLED_BACK')


def publish():
    current = json.loads(RECEIPT.read_text())
    if current['state'] != 'SOURCE_LOCAL' or git('rev-parse', 'HEAD') != NEW:
        raise RuntimeError('source publication CAS failed')
    if git('ls-remote', 'origin', 'refs/heads/main').split()[0] != OLD:
        raise RuntimeError('remote main moved before publication')
    git('push', 'origin', f'{NEW}:refs/heads/main')
    if git('ls-remote', 'origin', 'refs/heads/main').split()[0] != NEW:
        raise RuntimeError('remote readback mismatch; reconcile before rollback')
    receipt('SOURCE_PUBLISHED')
    print('SOURCE_PUBLISHED ' + NEW)


def verify_runtime():
    if git('rev-parse', 'HEAD') != NEW:
        raise RuntimeError('candidate source not active')
    model = json.loads(call('docker', 'compose', '-f', str(COMPOSE), 'config', '--format', 'json'))['services']['moss']
    active = json.loads(call('docker', 'inspect', 'the-ai-crowd-moss-1'))[0]
    expected = {m['target']: (m['source'], not m.get('read_only', False)) for m in model['volumes']}
    actual = {m['Destination']: (m['Source'], m['RW']) for m in active['Mounts']}
    if (model['image'] != NEXT_IMAGE or active['Image'] != NEXT_IMAGE or
            active['State']['Health']['Status'] != 'healthy' or expected != actual or
            '/agents/moss/private/projects' not in expected):
        raise RuntimeError('runtime not converged to canonical Compose')
    print('RUNTIME_CANONICAL_HEALTHY')


if __name__ == '__main__':
    {'check': check, 'prepare': prepare, 'rollback': rollback, 'publish': publish,
     'verify-runtime': verify_runtime}[sys.argv[1]]()
