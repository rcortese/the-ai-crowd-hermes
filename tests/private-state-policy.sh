#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import subprocess
from pathlib import Path

root = Path('.')
ignore = (root / '.gitignore').read_text(errors='ignore')
required_ignores = [
    '/.openclaw/',
    '/AGENTS.md',
    '/HEARTBEAT.md',
    '/IDENTITY.md',
    '/SOUL.md',
    '/TOOLS.md',
    '/USER.md',
    'agents/*/private/',
    'agents/*/.env',
    'agents/*/auth.json',
    'agents/*/ollama_cloud_models_cache.json',
    'agents/*/.gitconfig',
    'agents/*/.local/',
    'agents/*/bin/',
    'agents/*/home/',
    'agents/*/cache/*',
    'agents/*/sessions/*',
    'agents/*/logs/*',
]
missing = [entry for entry in required_ignores if entry not in ignore]
if missing:
    raise SystemExit('missing private-state ignore rules: ' + ', '.join(missing))

tracked_private = subprocess.check_output(
    ['git', 'ls-files', 'agents/*/private'],
    text=True,
).splitlines()
if tracked_private:
    raise SystemExit('public repo tracks private root content:\n' + '\n'.join(tracked_private))

# Catch accidental submodule/gitlink staging for the ignored private repo.
ls_tree = subprocess.check_output(
    ['git', 'ls-files', '-s', 'agents/moss/private'],
    text=True,
).splitlines()
if ls_tree:
    raise SystemExit('public repo has index entries for agents/moss/private:\n' + '\n'.join(ls_tree))

status = subprocess.check_output(
    ['git', 'status', '--porcelain=v1', '--ignored=matching', '--', 'agents/moss/private'],
    text=True,
).splitlines()
if status and not all(line.startswith('!! ') for line in status):
    raise SystemExit('agents/moss/private is not only ignored in public repo status:\n' + '\n'.join(status))

private = root / 'agents' / 'moss' / 'private'
if private.exists():
    if not (private / '.git').exists():
        raise SystemExit('agents/moss/private exists but is not a nested Git repo')
    remotes = subprocess.check_output(
        ['git', '-C', str(private), 'remote'],
        text=True,
    ).splitlines()
    if remotes:
        raise SystemExit('agents/moss/private must not have a remote in the public scaffold')

forbidden_names = {
    '.env', 'auth.json', 'auth.lock', '.anthropic_oauth.json',
    'state.db', 'state.sqlite', 'cookies.txt', 'token.json',
}
for path in private.rglob('*') if private.exists() else []:
    if path.name in forbidden_names:
        raise SystemExit(f'forbidden runtime/private state found in skeleton: {path}')
    lower = path.name.lower()
    if lower.endswith(('.log', '.dump', '.sqlite', '.db')):
        raise SystemExit(f'forbidden runtime artifact found in skeleton: {path}')

print('private_state_policy_ok')
PY
