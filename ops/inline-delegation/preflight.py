#!/usr/bin/env python3
"""Read-only CAS gate for the Moss inline-delegation image swap."""
import hashlib
import json
import subprocess
from pathlib import Path

STACK = Path('/mnt/ssd/appdata/the-ai-crowd')
HERE = Path(__file__).resolve().parent
BASE = 'sha256:05838ef5c373b913f4a0652ca76f4f0ca827c6a18754b2616a39a6d02a9df005'
NEXT = 'sha256:14a0a1930c386a9342efae4db712d3dcd39a9c4298709dcc3e0b39863a612f30'
INPUTS = {
    'compose.yaml': (STACK / 'compose.yaml', 'd06cc789f262260598f44341f2e1de5f6b413c6d722b7382a403c70a5e0fa95f'),
    'Dockerfile': (HERE / 'Dockerfile', 'aba693d903521dd50323169823a2604fbf63307e47bed39aa47490da2d9b6852'),
    'apply.py': (HERE / 'apply.py', '06ada37f898c1f7c2213e9fa976ce44bc0efe1a34c27218cae337180d72e3e5d'),
    'build.sh': (HERE / 'build.sh', '472b8fbc8840e79cfdae2761fa898fd77d51dacd82fb869dae8045d1c12190dd'),
    'compose.override.yaml': (HERE / 'compose.override.yaml', '684070e3e2b74bbd766aed388a4f70642fd880bb231b5564025ecca235ce88ad'),
    'rollback.override.yaml': (HERE / 'rollback.override.yaml', 'ef8336cd19d4033e4e38bc476c867d151db2f8ea786ab54a209e9140637fd7ec'),
}

def run(*args):
    return subprocess.check_output(args, cwd=STACK, text=True).strip()

for name, (path, expected) in INPUTS.items():
    if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
        raise SystemExit(f'INPUT_DRIFT {name}')
active = json.loads(run('docker', 'inspect', 'the-ai-crowd-moss-1'))[0]
if active['Image'] != BASE or active['State']['Status'] != 'running' or active['State']['Health']['Status'] != 'healthy':
    raise SystemExit('ACTIVE_DRIFT')
if run('docker', 'image', 'inspect', 'local/moss-inline-delegation:prepared-v1', '--format', '{{.Id}}') != NEXT:
    raise SystemExit('CANDIDATE_DRIFT')
if run('docker', 'image', 'inspect', 'moss-terminal-aggregate:release-959381e4d17344398665f44b8e6407d7', '--format', '{{.Id}}') != BASE:
    raise SystemExit('BASE_TAG_DRIFT')
args = ('docker', 'compose', '-f', str(STACK / 'compose.yaml'), '-f', str(HERE / 'compose.override.yaml'))
model = json.loads(run(*args, 'config', '--format', 'json'))['services']['moss']
mounts = {m['Destination']: (m['Source'], m['RW']) for m in active['Mounts']}
expected_mounts = {m['target']: (m['source'], not m.get('read_only', False)) for m in model['volumes']}
if mounts != expected_mounts or model['image'] != NEXT:
    raise SystemExit('COMPOSE_DRIFT')
print(json.dumps({'status': 'READY', 'active_id': active['Id'], 'active_started': active['State']['StartedAt'], 'base': BASE, 'candidate': NEXT, 'mounts_equal': True}))
