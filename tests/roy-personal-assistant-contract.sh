#!/usr/bin/env bash
set -euo pipefail

python3 - <<'PY'
from pathlib import Path

root = Path('.')
roy_files = [
    root / 'agents/public/roy/AGENTS.md',
    root / 'agents/public/roy/SOUL.md',
    root / 'agents/public/roy/README.md',
    root / 'agents/public/roy/IDENTITY.md',
    root / 'agents/public/roy/docs/operating-model.md',
    root / 'agents/public/roy/TOOLS.md',
]
missing = [str(p) for p in roy_files if not p.is_file()]
if missing:
    raise SystemExit(f'roy_contract_failed: missing files: {missing}')

text_by_path = {p: p.read_text(encoding='utf-8') for p in roy_files}
combined = '\n'.join(text_by_path.values()).lower()

required = [
    'viviane',
    'personal assistant',
    'brazilian portuguese',
    'telegram',
    'one batch',
    'process each invoice independently',
    'never silently ignore earlier images',
    'never silently keep only the last',
    'google sheets',
    '44-digit access key',
    'ask viviane which spreadsheet',
    'do not claim a google write',
]
for phrase in required:
    if phrase not in combined:
        raise SystemExit(f'roy_contract_failed: missing required phrase: {phrase!r}')

legacy_forbidden = [
    'live-input and intake triage specialist',
    'roy turns live input into a safe routing packet',
    'roy classifies inbound material and prepares handoffs',
    'treat telegram as an intake surface',
    'handoff — concise packet',
]
for phrase in legacy_forbidden:
    if phrase in combined:
        raise SystemExit(f'roy_contract_failed: legacy wording still present: {phrase!r}')

soul = text_by_path[root / 'agents/public/roy/SOUL.md'].lower()
if 'bad style:' not in soul or 'handoff' not in soul:
    raise SystemExit('roy_contract_failed: SOUL must explicitly teach Roy not to say handoff to Viviane')

operating = text_by_path[root / 'agents/public/roy/docs/operating-model.md'].lower()
for phrase in ['count every received image', 'preserve all attachments', 'one outcome per file', 'saved', 'duplicate', 'needs_clearer_image']:
    if phrase not in operating:
        raise SystemExit(f'roy_contract_failed: operating model missing batch outcome phrase: {phrase!r}')

print('roy_personal_assistant_contract_ok')
PY
