#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export SCRIPT_DIR

python3 - <<'PY'
import os
from pathlib import Path

script_dir = Path(os.environ['SCRIPT_DIR']).resolve()

candidates = [
    script_dir.parent,              # mounted scaffold root: /agents/moss/public
]
if len(script_dir.parents) > 3:
    candidates.append(script_dir.parents[3])  # monorepo root: .../agents/public/moss/tests -> repo root

relative_required = [
    'AGENTS.md',
    'SOUL.md',
    'README.md',
    'contracts/operating-contract.md',
    'contracts/capability-boundary.md',
    'contracts/memory-contract.md',
    'contracts/kanban-contract.md',
    'contracts/ownership-boundary.md',
    'contracts/startup-checklist.md',
    'contracts/git-versioning.md',
    'contracts/review-gates.md',
]

monorepo_prefix = Path('agents/public/moss')

scaffold_root = None
required = None
for candidate in candidates:
    mounted_paths = [candidate / p for p in relative_required]
    monorepo_paths = [candidate / monorepo_prefix / p for p in relative_required]
    if all(p.is_file() for p in mounted_paths):
        scaffold_root = candidate
        required = mounted_paths
        break
    if all(p.is_file() for p in monorepo_paths):
        scaffold_root = candidate / monorepo_prefix
        required = monorepo_paths
        break

if scaffold_root is None or required is None:
    expected = '\n'.join(str(script_dir.parent / p) for p in relative_required)
    raise SystemExit('missing Moss contract files; checked mounted scaffold and monorepo layouts:\n' + expected)

missing = [str(p) for p in required if not p.is_file()]
if missing:
    raise SystemExit('missing Moss contract files:\n' + '\n'.join(missing))

bundle = '\n'.join(p.read_text(errors='ignore') for p in required)
required_terms = [
    'Moss',
    'Jen',
    'Denholm',
    'Richmond',
    'Roy',
    'The Elders',
    'private state',
    'review gate',
    'git',
    'startup',
    'capability',
]
for term in required_terms:
    if term not in bundle:
        raise SystemExit(f'missing required term: {term}')

forbidden_claims = [
    'Docker socket is mounted by default',
    'SSH keys are mounted by default',
    'OpenClaw gateway tools are available',
    'OpenClaw cron jobs are available',
    'messaging bindings are available',
    'private memory is available',
]
for claim in forbidden_claims:
    if claim.lower() in bundle.lower():
        raise SystemExit(f'forbidden default-capability claim: {claim}')

agents = (scaffold_root / 'AGENTS.md').read_text()
for link in [
    'contracts/startup-checklist.md',
    'contracts/operating-contract.md',
    'contracts/ownership-boundary.md',
]:
    if link not in agents:
        raise SystemExit(f'AGENTS.md missing contract link: {link}')

print('moss_contract_smoke_ok')
PY
