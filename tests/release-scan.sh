#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import re
import subprocess
from pathlib import Path

files = subprocess.check_output(
    ['git', 'ls-files', '--cached', '--others', '--exclude-standard'],
    text=True,
).splitlines()

ignore_text = Path('.gitignore').read_text(errors='ignore')
if 'agents/*/private/' not in ignore_text:
    raise SystemExit('.gitignore must ignore agents/*/private/')
tracked_private = subprocess.check_output(
    ['git', 'ls-files', 'agents/*/private'],
    text=True,
).splitlines()
if tracked_private:
    raise SystemExit('public repo tracks nested private content:\n' + '\n'.join(tracked_private))

# Public files may describe generic placeholder classes, but must not contain
# real private deployment identifiers or default unsafe authority.
secret_patterns = [
    (r'(?i)api[_-]?key\s*[:=]\s*[A-Za-z0-9_./+=-]{12,}', 'api key assignment'),
    (r'(?i)(access|refresh|id)[_-]?token\s*[:=]\s*[A-Za-z0-9_./+=-]{20,}', 'token assignment'),
    (r'-----BEGIN (OPENSSH|RSA|EC|DSA|PRIVATE) KEY-----', 'private key'),
]
private_location_patterns = [
    (r'(?<![A-Za-z0-9_./-])/home/[a-z_][a-z0-9_-]*(?:/|$)', 'literal user home path'),
    (r'(?<![A-Za-z0-9_.-])(?:10\.|172\.(?:1[6-9]|2[0-9]|3[0-1])\.|192\.168\.)\d{1,3}\.\d{1,3}\b', 'private IPv4 address'),
    (r'(?<![A-Za-z0-9_.-])[A-Za-z0-9-]+\.lan\b', 'LAN hostname'),
    (r'(?<![A-Za-z0-9_./-])/(?:mnt|media|srv)/(?:user|disk\d+|cache|ssd|private|secrets)(?:/|$)', 'private storage path'),
]
project_specific_patterns = [
    (r'(?i)\bunraid\b', 'specific private deployment platform'),
]
unsafe_mount_patterns = [
    (r'/var/run/docker\.sock\s*:', 'Docker socket bind mount'),
    (r'(?m)^\s*-\s*/\s*:', 'root filesystem bind mount'),
    (r'(?m)^\s*-\s*/home\s*:', 'home filesystem bind mount'),
]
kanban_privacy_patterns = [
    (r'(?i)Bearer\s+[A-Za-z0-9_./+=-]{12,}', 'bearer token in kanban/review artifact'),
    (r'(?i)Cookie:\s*[^\n]{12,}', 'cookie header in kanban/review artifact'),
    (r'(?i)raw[_ -]?log', 'raw log marker in kanban/review artifact'),
    (r'(?i)session[_ -]?dump', 'session dump marker in kanban/review artifact'),
    (r'(?i)(auth\.json|auth\.lock|\.env|\.anthropic_oauth\.json)', 'credential/provider state filename in kanban/review artifact'),
    (r'(?i)private_data_level"\s*:\s*"(?:private|secret|internal)"', 'non-public private_data_level in public example'),
]

forbidden_identity_patterns = [
    ('Moss' + r' 2\.0', 'alternate Moss version name'),
    ('Moss' + ' on Hermes', 'alternate Moss runtime name'),
    ('moss' + '-on-hermes', 'alternate Moss runtime slug'),
    ('moss' + '-v2', 'alternate Moss version slug'),
    (r'\baos ' + 'Elders\b', 'incorrect The Elders article'),
    (r'\bos ' + 'Elders\b', 'incorrect The Elders article'),
    ('The ' + 'The ' + 'Elders', 'duplicated The Elders name'),
]

for path_s in files:
    path = Path(path_s)
    parts = set(path.parts)
    name = path.name

    forbidden_names = {
        '.env',
        'config.yaml',
        'auth.json',
        'auth.lock',
        '.anthropic_oauth.json',
    }
    if name in forbidden_names:
        raise SystemExit(f'forbidden tracked/public state file: {path}')
    if {'auth', 'logs', 'cache', 'sessions', 'checkpoints'} & parts:
        raise SystemExit(f'forbidden tracked/public runtime directory: {path}')
    if 'private' in parts and len(parts) >= 3 and parts[0] == 'agents':
        raise SystemExit(f'forbidden tracked/public nested private repo content: {path}')
    if path_s.startswith('ops/secrets/') and name != '.gitkeep':
        raise SystemExit(f'forbidden tracked/public secret path: {path}')

    if not path.is_file():
        continue
    try:
        text = path.read_text(errors='ignore')
    except OSError:
        continue

    for pattern, label in secret_patterns + private_location_patterns + project_specific_patterns + forbidden_identity_patterns:
        if re.search(pattern, text):
            raise SystemExit(f'{path}: release scan matched {label}')

    if path.suffix in {'.yaml', '.yml'}:
        for pattern, label in unsafe_mount_patterns:
            if re.search(pattern, text):
                raise SystemExit(f'{path}: unsafe default mount matched {label}')

    if path_s.startswith('examples/') or path_s.startswith('schemas/') or path_s.endswith('kanban-workflow.md'):
        for pattern, label in kanban_privacy_patterns:
            if re.search(pattern, text):
                raise SystemExit(f'{path}: release scan matched {label}')

print('release_scan_ok')
PY
