#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
from pathlib import Path

cutover = Path('docs/operations/cutover-checklist.md').read_text(errors='ignore')
transition = Path('docs/operations/openclaw-transition.md').read_text(errors='ignore')
capability = Path('docs/operations/capability-lanes.md').read_text(errors='ignore')

required_cutover = [
    'not-production-live',
    'production-live',
    'Private smoke deploy',
    'Private state backup',
    'Restore rehearsal',
    'OpenClaw fallback status',
    'Operator approval',
    'Do not mark Moss-on-Hermes as `production-live`',
]
missing = [item for item in required_cutover if item not in cutover]
if missing:
    raise SystemExit('cutover_policy_failed: missing cutover terms: ' + ', '.join(missing))

required_transition = [
    'Heartbeat, reminder, and OpenClaw cron behavior remain in OpenClaw',
    'The Hermes scaffold must not reimplement, schedule, or claim ownership of the OpenClaw heartbeat concept',
    'Heartbeat/reminders | OpenClaw only | out of Hermes scope by current decision',
    'Lossless',
    'fallback',
]
missing = [item for item in required_transition if item not in transition]
if missing:
    raise SystemExit('cutover_policy_failed: missing OpenClaw transition terms: ' + ', '.join(missing))

for forbidden in [
    'Heartbeat Hermes scheduler',
    'Hermes heartbeat owner',
    'migrate heartbeat to Hermes',
]:
    if forbidden.lower() in (cutover + transition + capability).lower():
        raise SystemExit('cutover_policy_failed: forbidden heartbeat migration phrase: ' + forbidden)

print('cutover_policy_ok')
PY
