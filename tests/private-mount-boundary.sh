#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
from pathlib import Path

boundary = Path('docs/operations/private-mount-boundary.md').read_text(errors='ignore')
public_private = Path('docs/architecture/public-private-boundary.md').read_text(errors='ignore')
compose = Path('compose.yaml').read_text(errors='ignore')
ignore = Path('.gitignore').read_text(errors='ignore')

required = [
    '`/workspace/the-ai-crowd` is **not automatically public-safe**',
    'agents/*/private/',
    'sentinel test',
    'public-source mount',
]
missing = [item for item in required if item not in boundary]
if missing:
    raise SystemExit('private_mount_boundary_failed: missing boundary terms: ' + ', '.join(missing))

if './agents/moss:/opt/data' not in compose or '.:/workspace/the-ai-crowd:ro' not in compose:
    raise SystemExit('private_mount_boundary_failed: expected base mount pattern changed; update boundary doc/test')

for rule in ['agents/*/private/', 'agents/*/sessions/*', 'agents/*/cache/*', 'agents/*/logs/*']:
    if rule not in ignore:
        raise SystemExit('private_mount_boundary_failed: missing ignore rule ' + rule)

if 'Private and ignored' not in public_private or 'agents/moss/private/' not in public_private:
    raise SystemExit('private_mount_boundary_failed: public/private architecture doc lost private-root guidance')

print('private_mount_boundary_ok')
PY
