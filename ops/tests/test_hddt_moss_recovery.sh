#!/usr/bin/env bash
# Recovery has executable coverage in the shared fake-first matrix; assert its
# dedicated T34–T40/T49 evidence rather than scanning implementation text.
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
out=$(mktemp /tmp/hddt-recovery-output.XXXXXX)
trap 'rm -f "$out"' EXIT
bash "$root/ops/tests/test_hddt_moss.sh" >"$out"
for t in T34 T35 T36 T37 T38 T39 T40 T49; do grep -qx "$t PASS" "$out" >/dev/null; done
printf '%s\n' 'hddt-recovery: T34-T40,T49 PASS'
