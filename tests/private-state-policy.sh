#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import subprocess
from pathlib import Path

ignore = Path('.gitignore').read_text(errors='ignore')
required = ['/agents/private/', '/runtime/', '/state/', '/secrets/', '/backups/']
missing = [entry for entry in required if entry not in ignore]
if missing:
    raise SystemExit('missing private/runtime ignore rules: ' + ', '.join(missing))

tracked = subprocess.check_output(['git', 'ls-files', 'agents/private'], text=True).splitlines()
if tracked:
    raise SystemExit('public repo tracks private workspace content:\n' + '\n'.join(tracked))

status = subprocess.check_output(
    ['git', 'status', '--porcelain=v1', '--ignored=matching', '--', 'agents/private'],
    text=True,
).splitlines()
if status and not all(line.startswith('!! ') for line in status):
    raise SystemExit('agents/private has non-ignored public status:\n' + '\n'.join(status))

for old in ['agents/moss/private', 'agents/richmond/private', 'agents/the-elders/private']:
    entries = subprocess.check_output(['git', 'ls-files', old], text=True).splitlines()
    if entries:
        raise SystemExit(f'public repo tracks old private path {old}:\n' + '\n'.join(entries))

print('private_state_policy_ok')
PY
