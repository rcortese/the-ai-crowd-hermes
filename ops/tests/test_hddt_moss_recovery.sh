#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
script="$root/ops/scripts/hddt-moss.sh"
[[ -x "$script" ]] || { echo 'missing HDDT executor' >&2; exit 1; }
grep -Fq 'recover)' "$script"
grep -Fq 'RECOVERY_UNRESOLVED' "$script"
grep -Fq 'ROLLBACK_FAILED' "$script"
grep -Fq 'trap' "$script"
echo 'hddt-recovery-contract: PASS'
