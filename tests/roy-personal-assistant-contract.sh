#!/usr/bin/env bash
set -euo pipefail

python3 - <<'PY'
import re
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
    'personal assistant',
    'configured trusted user',
    'brazilian portuguese',
    'configured chat channel',
    'one batch',
    'process each invoice independently',
    'never silently ignore earlier images',
    'never silently keep only the last',
    'google sheets',
    '44-digit access key',
    'ask which spreadsheet',
    'do not claim a google write',
]
for phrase in required:
    if phrase not in combined:
        raise SystemExit(f'roy_contract_failed: missing required phrase: {phrase!r}')

forbidden_phrases = [
    'live-input and intake triage specialist',
    'roy turns live input into a safe routing packet',
    'roy classifies inbound material and prepares handoffs',
    'treat telegram as an intake surface',
    'handoff — concise packet',
]
for phrase in forbidden_phrases:
    if phrase in combined:
        raise SystemExit(f'roy_contract_failed: forbidden public wording still present: {phrase!r}')

forbidden_patterns = [
    (r'@[a-z0-9_]{6,}', 'real channel handle'),
    (r'legacy\s+' + r'open' + r'claw|\bopen' + r'claw\b', 'legacy migration wording'),
    (r'\b[a-z]+\s+is\s+the\s+only\s+intended\s+day-to-day\s+user\b', 'named day-to-day user'),
]
for pattern, label in forbidden_patterns:
    if re.search(pattern, combined, re.IGNORECASE):
        raise SystemExit(f'roy_contract_failed: forbidden public {label} still present')

soul = text_by_path[root / 'agents/public/roy/SOUL.md'].lower()
if 'bad style:' not in soul or 'handoff' not in soul:
    raise SystemExit('roy_contract_failed: SOUL must explicitly teach Roy not to say handoff to the user')

operating = text_by_path[root / 'agents/public/roy/docs/operating-model.md'].lower()
for phrase in ['count every received image', 'preserve all attachments', 'one outcome per file', 'saved', 'duplicate', 'needs_clearer_image']:
    if phrase not in operating:
        raise SystemExit(f'roy_contract_failed: operating model missing batch outcome phrase: {phrase!r}')

print('roy_personal_assistant_contract_ok')
PY
