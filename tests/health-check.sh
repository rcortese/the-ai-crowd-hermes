#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

require_file() {
  if [ ! -f "$1" ]; then
    echo "health_check_failed: missing $1" >&2
    exit 1
  fi
}

require_file compose.yaml
require_file docs/PRODUCTION.md
require_file docs/ROLLBACK.md
require_file docs/operations/release-process.md
require_file docs/operations/backup-restore.md
require_file docs/operations/drift-detection.md

awk '
  /^    ports:/ { in_ports=1; next }
  in_ports && /^    [^ ]/ { in_ports=0 }
  in_ports && /^[[:space:]]+- / && $0 != "      - \"0.0.0.0:8644:8644\"" {
    print "health_check_failed: unexpected host port publication: " $0 > "/dev/stderr";
    exit 1;
  }
' compose.yaml

echo "host_port_policy_ok"

for forbidden in 'HERMES_DASHBOARD' 'command: ["hermes", "dashboard"'; do
  if grep -Fq "$forbidden" compose.yaml; then
    echo "health_check_failed: compose must not own Hermes runtime command/env: $forbidden" >&2
    exit 1
  fi
done

if grep -A2 -F 'command:' compose.yaml | grep -Eq '^[[:space:]]+- (gateway|hermes|dashboard)$'; then
  echo "health_check_failed: compose must not own Hermes runtime command list" >&2
  exit 1
fi

require_dockerfile_contract() {
  file="$1"
  shift
  for needle in "$@"; do
    if ! grep -Fq "$needle" "ops/images/$file"; then
      echo "health_check_failed: $file missing image-owned runtime contract: $needle" >&2
      exit 1
    fi
  done
}

require_dockerfile_contract Dockerfile.moss \
  'ENV HERMES_DASHBOARD=1' \
  'HERMES_DASHBOARD_PORT=9119' \
  'CMD ["gateway", "run"]'
require_dockerfile_contract Dockerfile.jen \
  'ENV HERMES_DASHBOARD=1' \
  'HERMES_DASHBOARD_PORT=9121' \
  'CMD ["gateway", "run"]'
require_dockerfile_contract Dockerfile.denholm \
  'ENV HERMES_DASHBOARD_TUI=1' \
  'CMD ["dashboard", "--host", "0.0.0.0", "--port", "9122"'
require_dockerfile_contract Dockerfile.richmond \
  'ENV HERMES_DASHBOARD_TUI=1' \
  'CMD ["dashboard", "--host", "0.0.0.0", "--port", "9120"'
require_dockerfile_contract Dockerfile.the-elders \
  'CMD ["dashboard", "--host", "0.0.0.0", "--port", "9130"'

echo "image_runtime_contract_ok"
echo "health_check_ok"
