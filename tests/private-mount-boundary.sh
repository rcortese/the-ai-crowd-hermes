#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
from pathlib import Path

compose = Path('compose.yaml').read_text(errors='ignore')
ignore = Path('.gitignore').read_text(errors='ignore')
boundary = Path('docs/operations/private-mount-boundary.md').read_text(errors='ignore')

for forbidden in ['.:/workspace/the-ai-crowd:ro', './agents:/', './agents/moss:/opt/data', '/mnt/moss-workspace']:
    if forbidden in compose:
        raise SystemExit('private_mount_boundary_failed: forbidden mount pattern in compose: ' + forbidden)

agents = ['moss', 'richmond', 'the-elders']
for agent in agents:
    public_mount = f'./agents/public/{agent}:/agents/{agent}/public:ro'
    private_mount = f'./agents/private/{agent}:/agents/{agent}/private:rw'
    if public_mount not in compose:
        raise SystemExit('private_mount_boundary_failed: missing public mount ' + public_mount)
    if private_mount not in compose:
        raise SystemExit('private_mount_boundary_failed: missing private rw mount ' + private_mount)

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
