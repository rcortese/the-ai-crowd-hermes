#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import json
import re
from pathlib import Path

OWNER_ENUM = ["moss", "jen", "denholm", "richmond", "roy", "the-elders", "operator"]
CARD_STATUSES = ["inbox", "triaged", "owned", "in_progress", "under_review", "changes_required", "blocked", "waiting_user", "approved", "done", "archived"]
CARD_TYPES = ["migration-task", "ops-task", "handoff", "review-gate", "incident", "decision-record", "automation-run", "blocker"]
HANDOFF_TYPES = ["consultation", "execution", "ownership_transfer", "return"]
GATE_STATUSES = ["requested", "under_review", "approved", "changes_required", "blocked", "stale"]
GATE_VERDICTS = ["APPROVED", "CHANGES_REQUIRED", "BLOCKED"]
HASH_RE = re.compile(r'^[0-9a-f]{7,64}$')
GATE_VERSION_RE = re.compile(r'^(commit:[0-9a-f]{7,64}|sha256:[0-9a-f]{64}|working-tree:[a-z0-9][a-z0-9-]{2,80})$')
ID_RE = re.compile(r'^[a-z0-9][a-z0-9-]{2,80}$')

required_files = [
    'docs/README.md',
    'docs/architecture/system-overview.md',
    'docs/architecture/public-private-boundary.md',
    'docs/architecture/agent-container-model.md',
    'docs/architecture/moss-architecture.md',
    'docs/architecture/mounts-and-capabilities.md',
    'docs/architecture/kanban-workflow.md',
    'docs/operations/private-memory-migration.md',
    'docs/operations/backup-restore.md',
    'docs/operations/release-process.md',
    'docs/operations/drift-detection.md',
    'docs/decisions/0001-public-scaffold-private-state.md',
    'agents/moss/contracts/operating-contract.md',
    'agents/moss/contracts/ownership-boundary.md',
    'agents/moss/contracts/startup-checklist.md',
    'agents/moss/contracts/capability-boundary.md',
    'agents/moss/contracts/memory-contract.md',
    'agents/moss/contracts/kanban-contract.md',
    'agents/moss/contracts/git-versioning.md',
    'agents/moss/contracts/review-gates.md',
    'agents/moss/tests/contract-smoke-test.sh',
    'tests/run-all.sh',
    'tests/history-scan.sh',
    'tests/smoke-deploy.sh',
    'tests/mount-policy.sh',
    'tests/release-scan.sh',
    'tests/image-pin.sh',
    'tests/health-check.sh',
    'tests/drift-detection.sh',
    'agents/moss/tools/wrappers/preflight-template.sh',
    'agents/moss/tools/wrappers/workspace-dirty-watch.sh',
    'agents/moss/tools/wrappers/README.md',
    'compose.project-mount.example.yaml',
    'ops/manifests/README.md',
    'ops/manifests/moss-capabilities.example.json',
    'ops/manifests/base-images.lock.json',
    'ops/policies/private-overlays.md',
    'ops/policies/capability-policy.md',
    'ops/policies/mount-policy.md',
    'schemas/kanban-card.schema.json',
    'schemas/handoff.schema.json',
    'schemas/review-gate.schema.json',
    'schemas/capability-manifest.schema.json',
    'examples/kanban-card.example.json',
    'examples/handoff.example.json',
    'examples/kanban/migration-task.example.json',
    'examples/kanban/blocker.example.json',
    'examples/kanban/waiting-user.example.json',
    'examples/handoffs/denholm-to-moss-execution.example.json',
    'examples/handoffs/moss-to-richmond-technical-support.example.json',
    'examples/handoffs/moss-to-jen-productivity-boundary.example.json',
    'examples/handoffs/ownership-transfer.example.json',
]

missing = [p for p in required_files if not Path(p).is_file()]
if missing:
    raise SystemExit('missing required files:\n' + '\n'.join(missing))

schemas = {}
for path in Path('schemas').glob('*.schema.json'):
    schemas[path.name] = json.loads(path.read_text())
    if schemas[path.name].get('$schema') != 'https://json-schema.org/draft/2020-12/schema':
        raise SystemExit(f'{path}: unexpected $schema')
    if schemas[path.name].get('type') != 'object':
        raise SystemExit(f'{path}: top-level type must be object')
    if 'required' not in schemas[path.name]:
        raise SystemExit(f'{path}: missing required list')

def require_keys(data, keys, path):
    missing = [key for key in keys if key not in data]
    if missing:
        raise SystemExit(f'{path}: missing required keys {missing}')

def require_public(path, data):
    if data.get('private_data_level') != 'public':
        raise SystemExit(f'{path}: public examples must set private_data_level=public')

def check_refs(path, refs):
    for ref in refs:
        if not isinstance(ref, str):
            raise SystemExit(f'{path}: refs must be strings')
        allowed = ('file:', 'commit:', 'test:', 'review:', 'summary:', 'private-ref:', 'sha256:')
        if not ref.startswith(allowed):
            raise SystemExit(f'{path}: unsafe evidence/artifact ref prefix: {ref}')

card_paths = sorted(Path('examples').glob('**/*.json'))
for path in card_paths:
    data = json.loads(path.read_text())
    path_s = str(path)
    if path_s.endswith('.example.json') and '/review-gates/' not in path_s and '/handoffs/' not in path_s and 'review-gate.example.json' not in path_s and 'handoff.example.json' not in path_s:
        pass

kanban_examples = [Path('examples/kanban-card.example.json'), *sorted(Path('examples/kanban').glob('*.json'))]
for path in kanban_examples:
    data = json.loads(path.read_text())
    require_keys(data, schemas['kanban-card.schema.json'].get('required', []), path)
    require_public(path, data)
    if not ID_RE.match(data['id']):
        raise SystemExit(f'{path}: invalid id')
    if data['type'] not in CARD_TYPES:
        raise SystemExit(f'{path}: invalid type')
    if data['owner'] not in OWNER_ENUM or data['decision_owner'] not in OWNER_ENUM:
        raise SystemExit(f'{path}: invalid owner or decision_owner')
    if 'executor' in data and data['executor'] not in OWNER_ENUM:
        raise SystemExit(f'{path}: invalid executor')
    if data['status'] not in CARD_STATUSES:
        raise SystemExit(f'{path}: invalid status')
    for commit in data.get('commit_refs', []):
        if not HASH_RE.match(commit):
            raise SystemExit(f'{path}: invalid commit ref {commit}')
    for key in ('source_refs', 'artifact_refs', 'evidence_refs'):
        check_refs(path, data.get(key, []))
    if data['status'] in {'blocked', 'waiting_user'}:
        for key in ('blocker_cause', 'next_action', 'unblock_condition'):
            if not data.get(key):
                raise SystemExit(f'{path}: {data["status"]} card requires {key}')
    if data['type'] in {'ops-task', 'automation-run'} and data.get('risk') == 'high' and not data.get('rollback_ref'):
        raise SystemExit(f'{path}: high-risk ops/automation cards require rollback_ref')

handoff_examples = [Path('examples/handoff.example.json'), *sorted(Path('examples/handoffs').glob('*.json'))]
for path in handoff_examples:
    data = json.loads(path.read_text())
    require_keys(data, schemas['handoff.schema.json'].get('required', []), path)
    require_public(path, data)
    if data['handoff_type'] not in HANDOFF_TYPES:
        raise SystemExit(f'{path}: invalid handoff_type')
    for key in ('from_owner', 'to_owner', 'decision_owner', 'return_to_owner'):
        if data[key] not in OWNER_ENUM:
            raise SystemExit(f'{path}: invalid {key}')
    if data['handoff_type'] != 'ownership_transfer' and data['decision_owner'] != data['return_to_owner']:
        raise SystemExit(f'{path}: non-transfer handoffs should return to the decision owner')
    if not data.get('privacy_constraints'):
        raise SystemExit(f'{path}: handoff requires privacy_constraints')

review_examples = sorted(Path('examples/review-gates').glob('*.json'))
for path in review_examples:
    data = json.loads(path.read_text())
    require_keys(data, schemas['review-gate.schema.json'].get('required', []), path)
    require_public(path, data)
    if not GATE_VERSION_RE.match(data['artifact_version']):
        raise SystemExit(f'{path}: artifact_version must be commit:<sha>, sha256:<hash>, or working-tree:<reason>')
    if data['status'] not in GATE_STATUSES:
        raise SystemExit(f'{path}: invalid status')
    if 'verdict' in data and data['verdict'] not in GATE_VERDICTS:
        raise SystemExit(f'{path}: invalid verdict')
    check_refs(path, [data['artifact_ref']])
    check_refs(path, data.get('evidence_refs', []))
    if data['status'] == 'stale' and not data.get('stale_reason'):
        raise SystemExit(f'{path}: stale review requires stale_reason')
    if data['status'] == 'changes_required' and not data.get('required_changes'):
        raise SystemExit(f'{path}: changes_required review requires required_changes')

capability_example = json.loads(Path('ops/manifests/moss-capabilities.example.json').read_text())
capability_schema = schemas['capability-manifest.schema.json']
require_keys(capability_example, capability_schema.get('required', []), 'ops/manifests/moss-capabilities.example.json')
agent_enum = capability_schema['properties']['agent']['enum']
if capability_example['agent'] not in agent_enum:
    raise SystemExit('capability example has invalid agent')
posture_enum = capability_schema['properties']['default_posture']['enum']
if capability_example['default_posture'] not in posture_enum:
    raise SystemExit('capability example has invalid default_posture')
cap_item = capability_schema['properties']['capabilities']['items']
cap_required = cap_item.get('required', [])
status_enum = cap_item['properties']['status']['enum']
for idx, cap in enumerate(capability_example.get('capabilities', [])):
    missing = [key for key in cap_required if key not in cap]
    if missing:
        raise SystemExit(f'capability {idx}: missing required keys {missing}')
    if cap['status'] not in status_enum:
        raise SystemExit(f'capability {idx}: invalid status {cap["status"]}')

print('schema_validation_ok')
PY
