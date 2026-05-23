#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../../.."

python3 - <<'PY'
from pathlib import Path

required = [
    'agents/moss/AGENTS.md',
    'agents/moss/SOUL.md',
    'agents/moss/README.md',
    'agents/moss/contracts/operating-contract.md',
    'agents/moss/contracts/capability-boundary.md',
    'agents/moss/contracts/memory-contract.md',
    'agents/moss/contracts/kanban-contract.md',
    'agents/moss/contracts/ownership-boundary.md',
    'agents/moss/contracts/startup-checklist.md',
    'agents/moss/contracts/git-versioning.md',
    'agents/moss/contracts/review-gates.md',
]
missing = [p for p in required if not Path(p).is_file()]
if missing:
    raise SystemExit('missing Moss contract files:\n' + '\n'.join(missing))

bundle = '\n'.join(Path(p).read_text(errors='ignore') for p in required)
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

agents = Path('agents/moss/AGENTS.md').read_text()
for link in [
    'contracts/startup-checklist.md',
    'contracts/operating-contract.md',
    'contracts/ownership-boundary.md',
]:
    if link not in agents:
        raise SystemExit(f'AGENTS.md missing contract link: {link}')

print('moss_contract_smoke_ok')
PY
