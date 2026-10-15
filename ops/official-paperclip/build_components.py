#!/usr/bin/env python3
"""Export pinned source, build/test official components and produce a closed MCP tree.

Only writes to a new --out directory under TMPDIR. Never installs into a runtime.
--resolve-runtime-lock is a maintainer-only resolution pass, not a locked release.
"""
import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile

HERE = Path(__file__).resolve().parent
PACKAGES = ['shared', 'adapter-utils', 'adapters/hermes', 'mcp-server']


def run(argv, cwd):
    subprocess.run([str(x) for x in argv], cwd=cwd, check=True)


def capture(argv, cwd):
    return subprocess.check_output([str(x) for x in argv], cwd=cwd, text=True).strip()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def pack_tree(root, target, prefix):
    """Canonical GNU tar + gzip (no timestamps/host owners or external links)."""
    with target.open('wb') as raw, gzip.GzipFile(filename='', mode='wb', fileobj=raw, mtime=0) as gz:
        with tarfile.open(fileobj=gz, mode='w', format=tarfile.GNU_FORMAT) as tar:
            for path in sorted(root.rglob('*')):
                if path.is_symlink():
                    path.resolve(strict=True).relative_to(root.resolve())
                    if os.path.isabs(os.readlink(path)):
                        raise ValueError('absolute symlink: ' + str(path))
                info = tar.gettarinfo(str(path), str(Path(prefix) / path.relative_to(root)))
                info.uid = info.gid = info.mtime = 0
                info.uname = info.gname = ''
                info.mode = 0o755 if path.is_dir() or (path.stat().st_mode & 0o111) else 0o644
                with path.open('rb') if info.isfile() else io.BytesIO() as stream:
                    tar.addfile(info, stream if info.isfile() else None)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--paperclip', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--resolve-runtime-lock', action='store_true')
    args = parser.parse_args()
    pin = json.loads((HERE / 'source.json').read_text())
    source = args.paperclip.resolve()
    commit = pin['commit']
    if capture(['git', 'rev-parse', commit + '^{tree}'], source) != pin['tree']:
        raise SystemExit('source_tree_mismatch')
    out = args.out.resolve()
    out.relative_to(Path(os.environ['TMPDIR']).resolve())
    out.mkdir(exist_ok=False, parents=True)
    snapshot = out / 'source'
    snapshot.mkdir()
    paths = ['tsconfig.base.json', 'patches/acpx@0.12.0.patch', 'LICENSE'] + ['packages/' + x for x in PACKAGES]
    archive = subprocess.check_output(['git', '-C', str(source), 'archive', commit, *paths])
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        tar.extractall(snapshot, filter='data')
    deps = out / 'build-deps'
    deps.mkdir()
    for name in ['package.json', 'package-lock.json']:
        shutil.copyfile(HERE / 'build-deps' / name, deps / name)
    run(['npm', 'ci', '--ignore-scripts', '--no-audit', '--no-fund'], deps)
    modules = deps / 'node_modules'
    (snapshot / 'node_modules').symlink_to(modules, target_is_directory=True)
    for package in PACKAGES:
        src = snapshot / 'packages' / package
        manifest = json.loads((src / 'package.json').read_text())
        manifest.update(manifest.get('publishConfig', {}))
        target = modules / manifest['name']
        target.mkdir(parents=True, exist_ok=False)
        write_json(target / 'package.json', manifest)
        (target / 'dist').symlink_to(src / 'dist', target_is_directory=True)
    patch = snapshot / 'patches/acpx@0.12.0.patch'
    run(['git', 'apply', '--check', patch], modules / 'acpx')
    run(['git', 'apply', patch], modules / 'acpx')
    for package in PACKAGES:
        run([modules / '.bin/tsc', '-p', snapshot / 'packages' / package / 'tsconfig.json'], snapshot)
    # Preserve the shared package's own distribution license/provenance build step.
    for name in ['LICENSE', 'PROVENANCE.md']:
        shutil.copyfile(snapshot / 'packages/shared/src/cliplab' / name,
                        snapshot / 'packages/shared/dist/cliplab' / name)
    run([modules / '.bin/vitest', 'run', '--config', 'packages/mcp-server/vitest.config.ts',
         'packages/mcp-server/src/run-context.test.ts', 'packages/mcp-server/src/api-origin.test.ts'], snapshot)
    run([modules / '.bin/vitest', 'run', '--config', 'packages/adapters/hermes/vitest.config.ts',
         'packages/adapters/hermes/src'], snapshot)
    runtime = out / 'paperclip-mcp'
    vendor = runtime / 'vendor'
    vendor.mkdir(parents=True)
    vendor_hashes = {}
    for package in ['shared', 'mcp-server']:
        src = snapshot / 'packages' / package
        dist = out / ('distribution-' + package)
        dist.mkdir()
        shutil.copytree(src / 'dist', dist / 'dist')
        for name in ['README.md', 'LICENSE']:
            original = src / name if (src / name).exists() else snapshot / name
            if original.exists():
                shutil.copyfile(original, dist / name)
        metadata = json.loads((src / 'package.json').read_text())
        metadata.update(metadata.pop('publishConfig', {}))
        # Resolve workspace dependency to the exact co-built distribution, not registry.
        if package == 'mcp-server':
            metadata['dependencies']['@paperclipai/shared'] = pin['sharedVersion']
        metadata.pop('devDependencies', None)
        metadata.pop('scripts', None)
        write_json(dist / 'package.json', metadata)
        # npm's bin link requires executable distribution entrypoint.
        if package == 'mcp-server':
            (dist / 'dist/stdio.js').chmod(0o755)
        tgz = vendor / (package + '.tgz')
        pack_tree(dist, tgz, 'package')
        vendor_hashes[tgz.name] = digest(tgz)
    write_json(runtime / 'package.json', {
        'name': 'official-paperclip-mcp-runtime', 'version': '0.1.0', 'private': True,
        'dependencies': {'@paperclipai/shared': 'file:vendor/shared.tgz',
                         '@paperclipai/mcp-server': 'file:vendor/mcp-server.tgz'},
        'engines': {'node': '>=24.11.0'}})
    lock = runtime / 'package-lock.json'
    if args.resolve_runtime_lock:
        run(['npm', 'install', '--package-lock-only', '--ignore-scripts', '--no-audit', '--no-fund'], runtime)
    else:
        shutil.copyfile(HERE / 'runtime-package-lock.json', lock)
    run(['npm', 'ci', '--omit=dev', '--ignore-scripts', '--no-audit', '--no-fund'], runtime)
    run(['npm', 'ls', '--omit=dev', '--all'], runtime)
    # These imports execute actual published exports, not source TS or scratch symlinks.
    run(['node', '--input-type=module', '-e',
         "await import('@paperclipai/shared'); await import('@paperclipai/mcp-server'); console.log('distribution-imports-ok')"], runtime)
    execute = snapshot / 'packages/adapters/hermes/src/gateway/server/execute.ts'
    if digest(execute) != pin['adapterPostimageSha256']:
        raise SystemExit('adapter_postimage_mismatch')
    shutil.copyfile(execute, out / 'execute.ts')
    archive_path = out / 'paperclip-mcp.tar.gz'
    pack_tree(runtime, archive_path, 'paperclip-mcp')
    manifest = {
        'source': pin, 'node': capture(['node', '--version'], out),
        'npm': capture(['npm', '--version'], out), 'productionEffects': 0,
        'lockedRelease': not args.resolve_runtime_lock,
        'vendorSha256': vendor_hashes,
        'buildLockSha256': digest(deps / 'package-lock.json'),
        'runtimeLockSha256': digest(lock),
        'artifacts': {p.name: {'sha256': digest(p), 'bytes': p.stat().st_size}
                      for p in [archive_path, out / 'execute.ts']},
    }
    write_json(out / 'manifest.json', manifest)
    print(json.dumps({'out': str(out), **manifest}, sort_keys=True))


if __name__ == '__main__':
    main()
