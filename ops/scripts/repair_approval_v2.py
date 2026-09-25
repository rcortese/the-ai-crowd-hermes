#!/usr/bin/env python3
"""Repair empty approval request_id on MEDIA, one explicitly selected service at a time.

Run as root in an interactive host terminal. --check reads only. Never run an
old failed invocation again without reconciling its receipt and the live state.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

ROOT = Path('/mnt/user/appdata/the-ai-crowd')
COMPOSE = ROOT / 'compose.yaml'
STATE = ROOT / 'state/private/approval-repair'
SERVICES = ('moss', 'roy')
SOURCE = '/opt/hermes-webui/api/runner_client.py'
OLD = '''    def respond_approval(self, run_id: str, approval_id: str, choice: str) -> dict[str, Any]:
        return self._post(
            f"/v1/runs/{urllib.parse.quote(str(run_id), safe='')}/approval",
            # Current Agent runs target request_id; retain the legacy wire key.
            {"choice": choice, "approval_id": approval_id, "request_id": approval_id},
        )'''
NEW = '''    def respond_approval(self, run_id: str, approval_id: str, choice: str) -> dict[str, Any]:
        body = {"choice": choice, "approval_id": approval_id}
        # The fallback with no Agent request identity must not send an explicit
        # empty request_id: the Runs endpoint rejects it as invalid.
        if approval_id:
            body["request_id"] = approval_id
        return self._post(
            f"/v1/runs/{urllib.parse.quote(str(run_id), safe='')}/approval",
            body,
        )'''
HEALTH = '''import json, urllib.request
u=urllib.request.urlopen('http://127.0.0.1:8787/health', timeout=5)
d=json.load(u)
assert d.get('status') == 'ok', 'WebUI not ok'
for k in ('active_runs', 'active_streams'):
    assert type(d.get(k)) is int and d[k] == 0, k+' not zero or absent'
print('WebUI healthy; active_runs=0; active_streams=0')
'''
READ_SOURCE = 'from pathlib import Path; print(Path(' + repr(SOURCE) + ').read_text(), end="")'
FAILURE_LOG = None


def run(*args, timeout=120):
    p = subprocess.run(args, text=True, capture_output=True, timeout=timeout)
    if p.returncode:
        # Docker/Compose diagnostics can contain credentials. Retain privately,
        # with the failing argv and stage, instead of throwing away the cause.
        if FAILURE_LOG is not None:
            with FAILURE_LOG.open('a') as log:
                log.write(json.dumps({'argv': args, 'returncode': p.returncode,
                                      'stdout': p.stdout, 'stderr': p.stderr}) + '\n')
            FAILURE_LOG.chmod(0o600)
        raise RuntimeError(f'{args[0]} failed (status {p.returncode}); private diagnostic: {FAILURE_LOG}')
    return p.stdout.strip()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def section(source, service):
    match = re.search(r'(?ms)^  ' + service + r':\n(.*?)(?=^  [a-z][a-z-]*:\n|\Z)', source)
    if match is None:
        raise RuntimeError('selected service not found in Compose')
    return match


def inspect(service):
    if os.geteuid() != 0 or run('hostname') != 'MEDIA':
        raise RuntimeError('must run as root on MEDIA')
    container_name = 'the-ai-crowd-' + service + '-1'
    container = json.loads(run('docker', 'inspect', container_name))[0]
    labels = container['Config']['Labels']
    if (labels.get('com.docker.compose.project') != 'the-ai-crowd'
            or labels.get('com.docker.compose.service') != service
            or not container['State']['Running']):
        raise RuntimeError('unexpected selected container')
    image = container['Image']
    if COMPOSE.is_symlink() or not COMPOSE.is_file():
        raise RuntimeError('Compose is not a regular file')
    source = COMPOSE.read_bytes()
    stanza = section(source.decode('utf-8'), service).group(1)
    image_line = re.search(r'(?m)^    image: (sha256:[0-9a-f]{64})$', stanza)
    if image_line is None or image_line.group(1) != image:
        raise RuntimeError('selected Compose image and running image disagree')
    installed = run('docker', 'exec', container_name, 'python3', '-c', READ_SOURCE) + '\n'
    if installed.count(OLD) != 1 or NEW in installed:
        raise RuntimeError('WebUI source differs from expected preimage; inspect manually')
    # Dockerfile FROM requires a locally resolvable NAME, not a bare sha256 image ID.
    metadata = json.loads(run('docker', 'image', 'inspect', image))[0]
    tags = [x for x in metadata.get('RepoTags') or [] if x.startswith('the-ai-crowd/' + service + '-all-in-one:')]
    if len(tags) != 1 or json.loads(run('docker', 'image', 'inspect', tags[0]))[0]['Id'] != image:
        raise RuntimeError('unique verified local base image tag unavailable')
    return source, image, installed, tags[0]


def idle(service):
    print(run('docker', 'exec', 'the-ai-crowd-' + service + '-1', 'python3', '-c', HEALTH, timeout=15))


def valid_compose():
    run('docker', 'compose', '-f', str(COMPOSE), '--project-directory', str(ROOT), 'config', '--quiet', timeout=30)


def atomic_compose(before, after):
    if COMPOSE.read_bytes() != before:
        raise RuntimeError('Compose changed concurrently')
    st = COMPOSE.stat()
    temporary = COMPOSE.with_name('.compose.approval-repair.' + str(os.getpid()))
    try:
        with temporary.open('xb') as file:
            os.fchmod(file.fileno(), st.st_mode & 0o777)
            os.fchown(file.fileno(), st.st_uid, st.st_gid)
            file.write(after)
            file.flush()
            os.fsync(file.fileno())
        if COMPOSE.read_bytes() != before:
            raise RuntimeError('Compose changed before replacement')
        os.replace(temporary, COMPOSE)
    finally:
        temporary.unlink(missing_ok=True)


def wait_health(service, image, seconds=150):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            current = json.loads(run('docker', 'inspect', 'the-ai-crowd-' + service + '-1'))[0]
            if (current['Image'] == image and current['State']['Running']
                    and current['State'].get('Health', {}).get('Status') == 'healthy'):
                return
        except (RuntimeError, KeyError, ValueError):
            pass
        time.sleep(3)
    raise RuntimeError('selected service did not become healthy with expected image')


def receipt(path, info):
    path.write_text(json.dumps(info, indent=2) + '\n')
    path.chmod(0o600)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('service', choices=SERVICES)
    parser.add_argument('--check', action='store_true', help='read-only plan')
    args = parser.parse_args()
    service = args.service
    before, old_image, installed, base_tag = inspect(service)
    valid_compose()
    print('Host MEDIA; service', service, '; current image', old_image)
    print('Compose SHA256', digest(before), 'WebUI source SHA256', digest(installed.encode()))
    print('Build base: verified local tag', base_tag)
    print('Impact: build candidate; recreate only', service, '; brief interruption of that service.')
    print('Recovery: original Compose bytes and original image retained; service-scoped Compose up.')
    print('Expected: healthy patched WebUI/gateway; approval button requires your manual test.')
    if args.check:
        print('CHECK ONLY: no build, deployment, or active-run clearance claimed.')
        return 0
    if not (sys.stdin.isatty() and sys.stdout.isatty()):
        raise RuntimeError('interactive host terminal required')
    idle(service)
    if input('Digite exatamente APLICAR ' + service + ' para continuar (Enter cancela): ') != 'APLICAR ' + service:
        print('Cancelado; nenhuma imagem/serviço alterado.')
        return 2
    STATE.mkdir(mode=0o700, parents=True, exist_ok=True)
    if STATE.is_symlink() or STATE.stat().st_uid != 0 or STATE.stat().st_mode & 0o077:
        raise RuntimeError('private state directory unsafe')
    with (STATE / 'lock').open('a+') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if inspect(service) != (before, old_image, installed, base_tag):
            raise RuntimeError('preimage changed after confirmation')
        idle(service)
        stamp = time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())
        work = STATE / ('run-' + service + '-' + stamp + '-' + str(os.getpid()))
        work.mkdir(mode=0o700)
        backup = work / 'compose.before'
        backup.write_bytes(before)
        backup.chmod(0o600)
        if backup.read_bytes() != before:
            raise RuntimeError('Compose backup verification failed')
        record = work / 'receipt.json'
        global FAILURE_LOG
        FAILURE_LOG = work / 'failures.jsonl'
        info = {'status': 'preparing', 'service': service, 'old_image': old_image,
                'base_tag': base_tag, 'compose_sha256': digest(before), 'new_image': None}
        receipt(record, info)
        print('Backup/receipt privados:', work)
        context = work / 'context'
        context.mkdir(mode=0o700)
        patched = installed.replace(OLD, NEW, 1)
        source = context / 'runner_client.py'
        source.write_text(patched)
        source.chmod(0o600)
        (context / 'Dockerfile').write_text('FROM ' + base_tag + '\nCOPY --chown=99:100 runner_client.py ' + SOURCE + '\n')
        tag = 'local/' + service + '-approval-repair:' + stamp.lower() + '-' + str(os.getpid())
        print('Building isolated candidate (no service interruption yet).')
        # Recheck that the local FROM tag still selects the reviewed base.
        if json.loads(run('docker', 'image', 'inspect', base_tag))[0]['Id'] != old_image:
            raise RuntimeError('base tag drifted before build')
        run('docker', 'build', '--pull=false', '--network=none', '--no-cache', '-t', tag, str(context), timeout=600)
        if json.loads(run('docker', 'image', 'inspect', base_tag))[0]['Id'] != old_image:
            raise RuntimeError('base tag drifted during build; candidate untrusted')
        new_image = run('docker', 'image', 'inspect', tag, '--format', '{{.Id}}')
        info.update(status='candidate_built', new_image=new_image)
        receipt(record, info)
        candidate = run('docker', 'run', '--rm', '--network', 'none', '--entrypoint', 'python3', tag,
                        '-c', READ_SOURCE, timeout=60) + '\n'
        if candidate != patched:
            raise RuntimeError('candidate WebUI bytes disagree')
        if COMPOSE.read_bytes() != before or json.loads(run('docker', 'inspect', 'the-ai-crowd-' + service + '-1'))[0]['Image'] != old_image:
            raise RuntimeError('Compose or selected container changed during build')
        idle(service)
        text = before.decode('utf-8')
        stanza = section(text, service)
        old_line = '    image: ' + old_image
        if stanza.group(1).count(old_line) != 1:
            raise RuntimeError('selected service image line changed')
        changed = text[:stanza.start(1)] + stanza.group(1).replace(old_line, '    image: ' + new_image, 1) + text[stanza.end(1):]
        after = changed.encode()
        info['status'] = 'lifecycle_attempted'
        receipt(record, info)
        try:
            atomic_compose(before, after)
            info['status'] = 'compose_replaced'
            receipt(record, info)
            valid_compose()
            info['status'] = 'compose_validated; recreating_selected_service'
            receipt(record, info)
            run('docker', 'compose', '-f', str(COMPOSE), '--project-directory', str(ROOT), 'up', '-d', '--no-deps', '--no-build', service, timeout=240)
            info['status'] = 'service_recreated; verifying_health'
            receipt(record, info)
            wait_health(service, new_image)
            actual = run('docker', 'exec', 'the-ai-crowd-' + service + '-1', 'python3', '-c', READ_SOURCE) + '\n'
            if actual != patched:
                raise RuntimeError('running WebUI source did not match candidate')
            ports = (8787, 8644, 8648) if service == 'moss' else (8787, 8644, 8645)
            run('docker', 'exec', 'the-ai-crowd-' + service + '-1', 'python3', '-c',
                'import urllib.request; [urllib.request.urlopen("http://127.0.0.1:%s/health"%p,timeout=5).close() for p in ' + repr(ports) + ']', timeout=20)
            info['status'] = 'healthy_patched_image; human_approval_test_pending'
            receipt(record, info)
            print('Imagem ativada, endpoints saudáveis e fonte verificada. Teste a aprovação na WebUI.')
            print('Recibo:', record)
            return 0
        except Exception as deployment_error:
            print('Falha após tentativa de implantação; tentando reversão somente de', service)
            info['status'] = 'rollback_attempted'
            info['deployment_error'] = str(deployment_error)
            receipt(record, info)
            try:
                if COMPOSE.read_bytes() == after:
                    atomic_compose(after, before)
                elif COMPOSE.read_bytes() != before:
                    raise RuntimeError('Compose drifted; automatic rollback unsafe')
                valid_compose()
                run('docker', 'compose', '-f', str(COMPOSE), '--project-directory', str(ROOT), 'up', '-d', '--no-deps', '--no-build', service, timeout=240)
                wait_health(service, old_image)
                info['status'] = 'rollback_healthy; original approval error remains'
                receipt(record, info)
                print('Imagem anterior restaurada e saudável; erro de aprovação original permanece.')
            except Exception:
                info['status'] = 'rollback_unverified; MANUAL_RECOVERY_REQUIRED'
                receipt(record, info)
                print('ATENÇÃO: reversão inconclusiva; inspecione o host.', file=sys.stderr)
            raise


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        print('Bloqueado/falhou:', type(error).__name__, str(error), file=sys.stderr)
        sys.exit(3)
