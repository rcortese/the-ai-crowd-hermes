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
    'activate.sh': (HERE / 'activate.sh', '34a7e4ecfa9bfdf6fafb9ed87c641a8bf9c44ee80908891cb5122a6318e1e0f2'),
    'rollback.sh': (HERE / 'rollback.sh', '70060d59d57f44ef7a726cca5925c978ea7a07f76f22d471c560889234234494'),
    'launch.sh': (HERE / 'launch.sh', 'a26f8a396e0029fcd0adaef2cefc660bc5a3eac1692672227d243b81cb424bf4'),
    'supervise.sh': (HERE / 'supervise.sh', 'e1902a943cacb165dfcb0dd2f9205cd84dc3dd8a02a774b97cee1439c87834ec'),
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
# A file hash alone does not pin env-file interpolation or other effective
# Compose settings. Freeze the complete rendered non-image/non-mount model;
# only the intended image and mount override may vary in this cutover.
projection = {key: value for key, value in model.items() if key not in ('image', 'volumes')}
projection_hash = hashlib.sha256(json.dumps(projection, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
if projection_hash != '6d10a7b4376d7163cdcb8cf5a5656cd6587674d264bd426a41d97748cbe63833':
    raise SystemExit('EFFECTIVE_COMPOSE_DRIFT')
runtime_env = dict(entry.split('=', 1) for entry in active['Config']['Env'] if '=' in entry)
if any(runtime_env.get(key) != str(value) for key, value in model['environment'].items()):
    raise SystemExit('ACTIVE_ENV_DRIFT')
if model['restart'] != active['HostConfig']['RestartPolicy']['Name']:
    raise SystemExit('ACTIVE_RESTART_DRIFT')
if model['user'] != active['Config']['User'] or model['working_dir'] != active['Config']['WorkingDir']:
    raise SystemExit('ACTIVE_PROCESS_DRIFT')
full_model = json.loads(run(*args, 'config', '--format', 'json'))
if sorted(full_model['networks'][key]['name'] for key in model['networks']) != sorted(active['NetworkSettings']['Networks']):
    raise SystemExit('ACTIVE_NETWORK_DRIFT')
expected_ports = {(str(port['target']) + '/' + port['protocol'], port['host_ip'], str(port['published']))
                  for port in model['ports']}
actual_ports = {(port, mapping['HostIp'], mapping['HostPort'])
                for port, mappings in (active['HostConfig']['PortBindings'] or {}).items()
                for mapping in mappings}
if expected_ports != actual_ports:
    raise SystemExit('ACTIVE_PORT_DRIFT')
mounts = {m['Destination']: (m['Source'], m['RW']) for m in active['Mounts']}
expected_mounts = {m['target']: (m['source'], not m.get('read_only', False)) for m in model['volumes']}
if mounts != expected_mounts or model['image'] != NEXT:
    raise SystemExit('COMPOSE_DRIFT')
print(json.dumps({'status': 'READY', 'active_id': active['Id'], 'active_started': active['State']['StartedAt'], 'base': BASE, 'candidate': NEXT, 'mounts_equal': True}))
