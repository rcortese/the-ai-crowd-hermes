"""Apply only a hash-bound Hermes metadata overlay during an authorized image build."""
import argparse
import hashlib
import json
from pathlib import Path
import stat
import subprocess


HERE = Path(__file__).resolve().parent


def digest(data):
    return hashlib.sha256(data).hexdigest()


def verify_files(root, entries, phase):
    for name, entry in entries.items():
        relative = Path(name)
        if relative.is_absolute() or '..' in relative.parts:
            raise ValueError(f"Invalid manifest path: {name}")
        path = root
        for part in relative.parts:
            path = path / part
            if path.is_symlink():
                raise ValueError(f"Symlink target refused: {name}")
        if not path.resolve().is_relative_to(root):
            raise ValueError(f"Target escapes source root: {name}")
        expected = entry[phase]
        if expected is None:
            if path.exists():
                raise ValueError(f"Expected absent {phase}: {name}")
            continue
        if not path.is_file() or digest(path.read_bytes()) != expected:
            raise ValueError(f"SHA-256 mismatch ({phase}): {name}")
        if stat.S_IMODE(path.stat().st_mode) != entry['mode']:
            raise ValueError(f"Mode mismatch ({phase}): {name}")


def apply(root, variant):
    root = Path(root).resolve(strict=True)
    manifest = json.loads((HERE / 'manifest.json').read_text())
    selected = manifest['variants'][variant]
    patch = HERE / selected['runtime_patch']['path']
    if digest(patch.read_bytes()) != selected['runtime_patch']['sha256']:
        raise ValueError('Patch SHA-256 mismatch')
    # Validate every preimage, including the unchanged OpenAI route, before ANY write.
    verify_files(root, selected['files'], 'pre')
    subprocess.run(['git', '-C', str(root), 'apply', '--check', '--whitespace=error-all', str(patch)], check=True)
    subprocess.run(['git', '-C', str(root), 'apply', '--whitespace=error-all', str(patch)], check=True)
    verify_files(root, selected['files'], 'post')
    for name in selected['files']:
        compile((root / name).read_bytes(), name, 'exec')
    return {'variant': variant, 'source_commit': selected['source_commit'],
            'runtime_patch_sha256': selected['runtime_patch']['sha256'],
            'postimages_verified': True, 'syntax_verified': True}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', required=True, type=Path)
    parser.add_argument('--variant', required=True, choices=('moss', 'non-moss'))
    args = parser.parse_args()
    print(json.dumps(apply(args.target, args.variant), sort_keys=True))
