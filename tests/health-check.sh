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

if grep -Eq '^[[:space:]]+ports:' compose.yaml; then
  echo "health_check_failed: public compose must not expose host ports" >&2
  exit 1
fi

if ! grep -Fq 'healthcheck:' compose.yaml; then
  echo "health_check_failed: compose.yaml must keep service healthcheck" >&2
  exit 1
fi

echo "health_check_ok"
