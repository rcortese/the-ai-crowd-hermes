#!/usr/bin/env python3
"""Host-side bounded activation. Never prints Compose configuration or credentials.

Run on the Docker host with --component server, or --component moss after draining
its active WebUI turn. Existing Compose inputs are preserved and compared in RAM.
A failed essential startup is recovered with the captured old image/input list.
Acceptance tests remain separate from container readiness.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time
from typing import Any

ROOT = Path('/mnt/user/appdata/the-ai-crowd/moss/home/profiles/moss')
STATE = ROOT / 'runtime/execution-candidates/paperclip-external-final/activation'
CONFIG = ROOT / 'config.yaml'
KEY = ROOT / 'secrets/paperclip-external-origin.key'
COMPANY = '9d914ba2-725e-4006-81f8-bc6f1eb1f411'
AGENT = '541d5e6d-2ba6-42ee-81b0-a5ab2d892a10'
BASES = {
    'server': 'sha256:d2e58200377fe592e39654c468d547c4b7bed3bee13cc174ee4bb19fbe596907',
    'moss': 'sha256:8ab3e813b0481043eaddb6ff09e839190a9bb2725f7474bf6b2a105e0291d833',
}
IMAGES = {
    'server': 'sha256:d3b1d6ca96f23f0df347712a5c4084fd87ac99ac69c3b7ba2db76e9030c1a02f',
    'moss': 'sha256:4048c7597b38fa3d81b0af10dcfeadc5e3c03dd65366e4dfff6bdf14a502606c',
}


def run(*args):
    return subprocess.check_output(args, text=True)


def inspect(container):
    return json.loads(run('docker', 'inspect', container))[0]


def save(path, obj):
    path.write_text(json.dumps(obj, indent=2) + '\n')
    path.chmod(0o600)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--component', choices=BASES, required=True)
    a = p.parse_args()
    name = 'paperclip-server-1' if a.component == 'server' else 'the-ai-crowd-moss-1'
    old = inspect(name)
    if old['Image'] != BASES[a.component]:
        p.error('live base changed or activation already applied; reconcile before retry')
    run('docker', 'image', 'inspect', IMAGES[a.component])
    labels = old['Config']['Labels']
    service = labels['com.docker.compose.service']
    files = labels['com.docker.compose.project.config_files'].split(',')
    cwd = labels['com.docker.compose.project.working_dir']
    command = ['docker', 'compose', '--project-directory', cwd, '-p', labels['com.docker.compose.project']]
    for f in files:
        if not Path(f).is_file():
            p.error('an original Compose input is unavailable')
        command += ['-f', f]
    STATE.mkdir(parents=True, exist_ok=True)
    override = STATE / (a.component + '.override.json')
    receipt = STATE / (a.component + '.receipt.json')
    if override.exists() or receipt.exists():
        p.error('activation state already exists; reconcile instead of overwriting')
    spec: dict[str, Any] = {'image': IMAGES[a.component]}
    if a.component == 'server':
        new_directory = not KEY.parent.exists()
        KEY.parent.mkdir(mode=0o700, exist_ok=True)
        if new_directory:
            os.chown(KEY.parent, 99, 100)
        if KEY.parent.stat().st_uid != 99:
            p.error('existing secret directory custody needs reconciliation')
        fd = os.open(KEY, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o640)
        try:
            os.fchown(fd, 99, 1000)
            os.write(fd, os.urandom(32))
            os.fsync(fd)
        finally:
            os.close(fd)
        spec.update(environment={
            'PAPERCLIP_EXTERNAL_ORIGIN_COMPANY_ID': COMPANY,
            'PAPERCLIP_EXTERNAL_ORIGIN_AGENT_ID': AGENT,
            'PAPERCLIP_EXTERNAL_ORIGIN_KEY_FILE': '/run/secrets/moss-paperclip-external-origin.key',
        }, volumes=[{'type': 'bind', 'source': str(KEY), 'target': '/run/secrets/moss-paperclip-external-origin.key', 'read_only': True}])
    else:
        if KEY.stat().st_size != 32:
            p.error('key missing or wrong size')
    save(override, {'services': {service: spec}})
    effective = command + ['-f', str(override)]
    before = json.loads(run(*command, 'config', '--format', 'json'))
    after = json.loads(run(*effective, 'config', '--format', 'json'))
    # Verify the full effective model: no other service/input/network may change.
    expected = json.loads(json.dumps(before))
    target = expected['services'][service]
    target['image'] = IMAGES[a.component]
    if a.component == 'server':
        target.setdefault('environment', {}).update(spec['environment'])
        target.setdefault('volumes', []).extend(after['services'][service]['volumes'][-1:])
        # Match by destination, not Compose's ordering, and require all old mounts.
        mounts = after['services'][service]['volumes']
        added = [v for v in mounts if v.get('target') == '/run/secrets/moss-paperclip-external-origin.key']
        if len(added) != 1:
            p.error('secret mount not unique')
        target['volumes'] = before['services'][service].get('volumes', []) + added
        for model in (expected, after):
            model['services'][service]['volumes'].sort(key=lambda v: v['target'])
    if before.get('name') != after.get('name') or expected != after:
        p.error('effective Compose changes exceed the selected image and explicit origin opt-in')
    info = {'component': a.component, 'oldImage': old['Image'], 'newImage': IMAGES[a.component],
            'originalComposeFiles': files, 'override': str(override), 'status': 'prepared'}
    save(receipt, info)
    old_config = CONFIG.read_bytes() if a.component == 'moss' else None
    if old_config is not None:
        needle = b'      PAPERCLIP_RUN_CONTEXT_MODE: request\n'
        replacement = (b'      PAPERCLIP_RUN_CONTEXT_MODE: request-or-external\n'
                       b'      PAPERCLIP_EXTERNAL_ORIGIN_KEY_FILE: /opt/data/profiles/moss/secrets/paperclip-external-origin.key\n')
        if old_config.count(needle) != 1 or b'PAPERCLIP_EXTERNAL_ORIGIN_KEY_FILE' in old_config:
            p.error('runtime config preimage does not match')
        CONFIG.write_bytes(old_config.replace(needle, replacement))
        info['configPreimageHash'] = hashlib.sha256(old_config).hexdigest()
        info['configPostimageHash'] = hashlib.sha256(CONFIG.read_bytes()).hexdigest()
        save(receipt, info)
    try:
        subprocess.run(effective + ['up', '-d', '--no-build', '--no-deps', '--force-recreate', service], check=True)
        deadline = time.monotonic() + 150
        while time.monotonic() < deadline:
            state = inspect(name)
            if state['Image'] != IMAGES[a.component]:
                raise RuntimeError('wrong active image')
            health = state['State'].get('Health', {}).get('Status')
            if health == 'healthy':
                info.update(status='applied-ready-not-accepted', containerId=state['Id'])
                save(receipt, info)
                print(json.dumps({'receipt': str(receipt), 'status': info['status']}))
                return
            if not state['State']['Running'] or health == 'unhealthy':
                raise RuntimeError('essential service failed startup')
            time.sleep(2)
        # An inconclusive check is not evidence for automatic rollback.
        info['status'] = 'applied-readiness-inconclusive'
        save(receipt, info)
        raise SystemExit('readiness inconclusive; inspect service; no automatic rollback')
    except (RuntimeError, subprocess.CalledProcessError) as exc:
        # Actual process/start failure, not an acceptance-test failure.
        if old_config is not None:
            if hashlib.sha256(CONFIG.read_bytes()).hexdigest() != info['configPostimageHash']:
                raise RuntimeError('config changed concurrently; recovery requires reconciliation') from exc
            CONFIG.write_bytes(old_config)
        rollback = STATE / (a.component + '.rollback.json')
        save(rollback, {'services': {service: {'image': old['Image']}}})
        subprocess.run(command + ['-f', str(rollback), 'up', '-d', '--no-build', '--no-deps', '--force-recreate', service], check=True)
        info['status'] = 'startup-failed-recovered-previous-image'
        save(receipt, info)
        raise


if __name__ == '__main__':
    main()
