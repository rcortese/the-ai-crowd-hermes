#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
from pathlib import Path

lanes = Path('docs/operations/capability-lanes.md').read_text(errors='ignore')
required = [
    'Lane: external messaging',
    'Lane: private-host SSH',
    'Lane: Docker/Compose host control',
    'Lane: project file mounts',
    'Lane: OpenClaw runtime transition support',
    'Lane: private memory',
    'Heartbeat behavior/reminders | OpenClaw only; not migrated to Hermes',
]
missing = [item for item in required if item not in lanes]
if missing:
    raise SystemExit('capability_lanes_failed: missing lane terms: ' + ', '.join(missing))

manifest = Path('ops/manifests/moss-capabilities.example.json').read_text(errors='ignore')
for capability in ['messaging_direct_notice', 'ssh_readonly_preflight', 'compose_readonly_preflight', 'openclaw_transition_support']:
    if capability not in manifest:
        raise SystemExit(f'capability_lanes_failed: missing manifest capability {capability}')
print('capability_lanes_docs_ok')
PY

agents/public/moss/tools/wrappers/messaging-dry-run.sh \
  --channel direct-message \
  --recipient private-ref:operator-direct \
  --message 'public scaffold dry run' \
  --dry-run >/dev/null

if agents/public/moss/tools/wrappers/messaging-dry-run.sh --channel direct-message --recipient private-ref:operator --message test --live >/tmp/hermes-message-live.out 2>/tmp/hermes-message-live.err; then
  echo 'capability_lanes_failed: messaging live mode unexpectedly succeeded' >&2
  exit 1
fi

agents/public/moss/tools/wrappers/ssh-readonly-preflight.sh \
  --host-ref private-ref:private-infra-host \
  --user-ref private-ref:private-infra-user \
  --command-class host-summary \
  --dry-run >/dev/null

agents/public/moss/tools/wrappers/compose-readonly-preflight.sh \
  --repo . \
  --mode config \
  --dry-run >/dev/null

echo 'capability_lanes_ok'
