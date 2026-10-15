"""Executable fail-closed overlay matrix; export only allowlisted Git source blobs."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parents[1]


def file_state(root, entries):
    state = {}
    for name in entries:
        path = root / name
        if path.is_symlink():
            state[name] = ('symlink', str(path.readlink()))
        elif path.exists():
            state[name] = (hashlib.sha256(path.read_bytes()).hexdigest(), stat.S_IMODE(path.stat().st_mode))
        else:
            state[name] = None
    return state


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-moss', required=True, type=Path)
    parser.add_argument('--source-non-moss', required=True, type=Path)
    parser.add_argument('--scratch', required=True, type=Path)
    args = parser.parse_args()
    manifest = json.loads((HERE/'manifest.json').read_text())
    cases = []
    for variant, repo in [('moss', args.source_moss), ('non-moss', args.source_non_moss)]:
        selected = manifest['variants'][variant]
        for scenario in ['apply', 'source-patch', 'bytes-drift', 'mode-drift', 'new-file-present',
                         'wrong-variant', 'symlink', 'patch-drift']:
            with tempfile.TemporaryDirectory(prefix='metadata-overlay-', dir=args.scratch) as tmp:
                fixture = Path(tmp)/'source'
                fixture.mkdir()
                entries = selected['source_files'] if scenario == 'source-patch' else selected['files']
                for name, entry in entries.items():
                    if entry['pre'] is None:
                        continue
                    content = subprocess.check_output(['git', '-C', str(repo), 'show',
                                                        selected['base_commit']+':'+name])
                    assert hashlib.sha256(content).hexdigest() == entry['pre']
                    path = fixture/name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(content)
                    path.chmod(entry['mode'])
                if scenario == 'source-patch':
                    patch = HERE/selected['source_patch']['path']
                    assert hashlib.sha256(patch.read_bytes()).hexdigest() == selected['source_patch']['sha256']
                    subprocess.run(['git','-C',str(fixture),'apply','--check',str(patch)], check=True)
                    subprocess.run(['git','-C',str(fixture),'apply',str(patch)], check=True)
                    for name, entry in entries.items():
                        assert hashlib.sha256((fixture/name).read_bytes()).hexdigest() == entry['post']
                    cases.append({'variant': variant, 'scenario': scenario, 'passed': True})
                    continue
                overlay = HERE
                choice = variant
                victim = fixture/'gateway/platforms/api_server.py'
                if scenario == 'bytes-drift':
                    victim.write_bytes(victim.read_bytes()+b'\n# unrelated newer change\n')
                elif scenario == 'mode-drift':
                    victim.chmod(0o600)
                elif scenario == 'new-file-present':
                    (fixture/'gateway/platforms/api_server_mcp_metadata.py').write_text('# already exists\n')
                elif scenario == 'wrong-variant':
                    choice = 'non-moss' if variant == 'moss' else 'moss'
                elif scenario == 'symlink':
                    replacement = Path(tmp)/'unrelated.py'
                    replacement.write_bytes(victim.read_bytes())
                    victim.unlink()
                    victim.symlink_to(replacement)
                elif scenario == 'patch-drift':
                    overlay = Path(tmp)/'overlay'
                    shutil.copytree(HERE, overlay)
                    (overlay/selected['runtime_patch']['path']).write_text('invalid patch\n')
                before = file_state(fixture, selected['files'])
                result = subprocess.run([sys.executable, str(overlay/'apply.py'), '--target', str(fixture),
                                         '--variant', choice], capture_output=True, text=True)
                if scenario == 'apply':
                    assert result.returncode == 0, result.stderr
                    receipt = json.loads(result.stdout)
                    assert receipt['postimages_verified'] and receipt['syntax_verified']
                    subprocess.run(['git','-C',str(fixture),'apply','--reverse','--check',
                                    str(HERE/selected['runtime_patch']['path'])], check=True)
                    again = subprocess.run([sys.executable, str(HERE/'apply.py'), '--target', str(fixture),
                                            '--variant', variant], capture_output=True)
                    assert again.returncode != 0, 'reapplication must not be accepted'
                else:
                    assert result.returncode != 0, (variant, scenario, result.stdout)
                    assert file_state(fixture, selected['files']) == before, 'failure wrote source'
                cases.append({'variant': variant, 'scenario': scenario, 'passed': True})
    print(json.dumps({'passed_cases': len(cases), 'cases': cases, 'runtime_touched': False}))


if __name__ == '__main__':
    main()
