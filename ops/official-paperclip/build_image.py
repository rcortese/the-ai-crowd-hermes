#!/usr/bin/env python3
"""Build a uniquely tagged local overlay on an immutable existing image, then smoke it.

Docker endpoint must be explicit (for MEDIA: --docker-host ssh://media). No push/deploy APIs.
Each --out is a new directory beneath TMPDIR. The context is allowlisted and has
no credentials/home/socket mounts, registry pulls, ports or build-time network.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile

HERE = Path(__file__).resolve().parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inspect(image):
    return json.loads(subprocess.check_output(['docker', 'image', 'inspect', image]))[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--docker-host', required=True, help='Explicit Docker endpoint; no implicit local socket')
    parser.add_argument('--components', required=True, type=Path)
    parser.add_argument('--role', required=True, choices=['moss', 'denholm', 'jen', 'richmond', 'adapter'])
    parser.add_argument('--base', help='Optional immutable MCP base for a separately authorized layer chain')
    parser.add_argument('--tag', required=True)
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args()
    os.environ['DOCKER_HOST'] = args.docker_host
    pin = json.loads((HERE / 'source.json').read_text())
    manifest = json.loads((args.components / 'manifest.json').read_text())
    if manifest['source'] != pin or not manifest['lockedRelease']:
        raise SystemExit('source_or_locked_release_mismatch')
    for name, data in manifest['artifacts'].items():
        if name not in {'execute.ts', 'paperclip-mcp.tar.gz'} or sha(args.components / name) != data['sha256']:
            raise SystemExit('artifact_integrity_mismatch')
    if set(manifest['artifacts']) != {'execute.ts', 'paperclip-mcp.tar.gz'}:
        raise SystemExit('artifact_set_mismatch')
    if manifest['runtimeLockSha256'] != sha(HERE / 'runtime-package-lock.json'):
        raise SystemExit('runtime_lock_mismatch')
    adapter = args.role == 'adapter'
    base = args.base or (pin['serverBaseImage'] if adapter else pin['runtimeBaseImages'][args.role])
    if not re.fullmatch(r'(sha256:[0-9a-f]{64}|[a-zA-Z0-9./_-]+@sha256:[0-9a-f]{64})', base):
        raise SystemExit('immutable_base_required')
    if adapter and base != pin['serverBaseImage']:
        raise SystemExit('adapter_base_mismatch')
    if not re.fullmatch(r'[a-z0-9][a-z0-9/._-]*:tac246-[a-z0-9._-]+', args.tag):
        raise SystemExit('unique_tac246_tag_required')
    # Never repoint any existing tag, including a previous candidate.
    if subprocess.run(['docker', 'image', 'inspect', args.tag], stdout=subprocess.DEVNULL,
                      stderr=subprocess.DEVNULL).returncode == 0:
        raise SystemExit('candidate_tag_already_exists')
    before = inspect(base)
    out = args.out.resolve()
    out.relative_to(Path(os.environ['TMPDIR']).resolve())
    out.mkdir(parents=True, exist_ok=False)
    context = out / 'context'
    context.mkdir()
    recipe = HERE / ('Dockerfile.adapter' if adapter else 'Dockerfile.mcp')
    shutil.copyfile(recipe, context / 'Dockerfile')
    if adapter:
        shutil.copyfile(args.components / 'execute.ts', context / 'execute.ts')
        if sha(context / 'execute.ts') != pin['adapterPostimageSha256']:
            raise SystemExit('adapter_postimage_mismatch')
    else:
        with tarfile.open(args.components / 'paperclip-mcp.tar.gz') as tar:
            for member in tar.getmembers():
                if not member.name.startswith('paperclip-mcp/'):
                    raise SystemExit('unexpected_runtime_tar_prefix')
            tar.extractall(context, filter='data')
    iid = out / 'iid'
    subprocess.run(['docker', 'build', '--pull=false', '--network=none', '--iidfile', str(iid),
                    '--build-arg', 'BASE_IMAGE=' + base, '-t', args.tag, str(context)], check=True)
    image = iid.read_text().strip()
    built = inspect(image)
    if inspect(base)['Id'] != before['Id']:
        raise SystemExit('base_changed')
    if built['RootFS']['Layers'][:len(before['RootFS']['Layers'])] != before['RootFS']['Layers']:
        raise SystemExit('base_layer_mismatch')
    for field in ['Entrypoint', 'Cmd', 'Env', 'WorkingDir', 'User']:
        if built['Config'].get(field) != before['Config'].get(field):
            raise SystemExit('inherited_config_changed:' + field)
    command = ['docker', 'run', '--rm', '--network=none', '--read-only', '--cap-drop=ALL',
               '--security-opt=no-new-privileges', '--pids-limit=64', '--memory=512m', '--cpus=1']
    if adapter:
        # Source exports remain native TS through tsx; do not run the server/entrypoint.
        command += ['--workdir=/app/server', '--entrypoint=node', image, '--import', 'tsx', '--input-type=module', '-e',
                    'await import("/app/packages/adapters/hermes/src/gateway/server/execute.ts"); console.log("native-adapter-import-ok")']
        result = subprocess.run(command, text=True, capture_output=True)
        (out / 'smoke.stdout').write_text(result.stdout)
        (out / 'smoke.stderr').write_text(result.stderr)
        result.check_returncode()
        if result.stdout.strip() != 'native-adapter-import-ok':
            raise SystemExit('adapter_import_smoke_mismatch')
        smoke = {'status': 'PASS', 'nativeAdapterImport': True, 'productionEffects': 0}
    else:
        command += ['--user=99:100', '-i', '--entrypoint=python3', image, '-',
                    '/opt/paperclip-mcp/node_modules/.bin/paperclip-mcp-server']
        result = subprocess.run(command, input=(HERE / 'smoke_mcp.py').read_text(),
                                text=True, capture_output=True)
        (out / 'smoke.stdout').write_text(result.stdout)
        (out / 'smoke.stderr').write_text(result.stderr)
        result.check_returncode()
        smoke = json.loads(result.stdout)
        if smoke['status'] != 'PASS':
            raise SystemExit('mcp_smoke_mismatch')
    docker_warning = 'WARNING: Your kernel does not support swap limit capabilities or the cgroup is not mounted. Memory limited without swap.\n'
    if result.stderr not in {'', docker_warning}:
        raise SystemExit('unexpected_smoke_stderr')
    receipt = {'role': args.role, 'base': base, 'baseImageId': before['Id'], 'imageId': image,
               'tag': args.tag, 'recipeSha256': sha(recipe), 'source': pin,
               'artifactManifestSha256': sha(args.components / 'manifest.json'),
               'smoke': smoke, 'dockerWarnings': result.stderr.strip(), 'inheritedConfigPreserved': True,
               'dockerEndpoint': os.environ.get('DOCKER_HOST', 'default'), 'productionEffects': 0}
    (out / 'receipt.json').write_text(json.dumps(receipt, sort_keys=True, indent=2) + '\n')
    print(json.dumps(receipt, sort_keys=True))


if __name__ == '__main__':
    main()
