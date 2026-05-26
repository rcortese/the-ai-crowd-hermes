#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCAFFOLD_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCAFFOLD_ROOT

python3 - <<'PYCODE'
import os
from pathlib import Path

scaffold_root = Path(os.environ['SCAFFOLD_ROOT']).resolve()

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
required = [scaffold_root / p for p in relative_required]

missing = [str(p.relative_to(scaffold_root)) for p in required if not p.is_file()]
if missing:
    raise SystemExit('missing Moss contract files under scaffold root:\n' + '\n'.join(missing))

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
PYCODE
