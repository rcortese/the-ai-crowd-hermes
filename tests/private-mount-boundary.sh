#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import re
from pathlib import Path

compose = Path('compose.yaml').read_text(errors='ignore')
ignore = Path('.gitignore').read_text(errors='ignore')
boundary = Path('docs/operations/private-mount-boundary.md').read_text(errors='ignore')

for forbidden in ['.:/workspace/the-ai-crowd:ro', './agents:/', './agents/moss:/opt/data', '/mnt/moss-workspace']:
    if forbidden in compose:
        raise SystemExit('private_mount_boundary_failed: forbidden mount pattern in compose: ' + forbidden)

for agent in ['richmond', 'the-elders']:
    public_mount = f'./agents/public/{agent}:/agents/{agent}/public:ro'
    private_mount = f'./agents/private/{agent}:/agents/{agent}/private:rw'
    if public_mount not in compose:
        raise SystemExit('private_mount_boundary_failed: missing public mount ' + public_mount)
    if private_mount not in compose:
        raise SystemExit('private_mount_boundary_failed: missing private rw mount ' + private_mount)

# Moss runs from an immutable runtime snapshot: public contract and source are
# read-only; only the projects directory is writable.
moss_mounts = [
    (r'\./runtime/moss-public-\S+:/agents/moss/public:ro', 'public snapshot mount (read-only)'),
    (r'\./runtime/moss-source-\S+:/agents/moss/private:ro', 'private source snapshot mount (read-only)'),
    (r'source: \./runtime/moss-source-\S+/projects\s+target: /agents/moss/private/projects\s+read_only: false', 'writable projects bind'),
]
for pattern, label in moss_mounts:
    if not re.search(pattern, compose):
        raise SystemExit('private_mount_boundary_failed: missing Moss ' + label)

if '/agents/private/' not in ignore:
    raise SystemExit('private_mount_boundary_failed: .gitignore must ignore /agents/private/')

required_terms = [
    'agents/public/<agent>/',
    'agents/private/<agent>/',
    '/agents/<agent>/public',
    '/agents/<agent>/private',
]
missing = [term for term in required_terms if term not in boundary]
if missing:
    raise SystemExit('private_mount_boundary_failed: boundary doc missing ' + ', '.join(missing))

print('private_mount_boundary_ok')
PY
