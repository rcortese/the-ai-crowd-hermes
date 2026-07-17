#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
validator="$root/tests/validate-adrs.py"
run_ok() { "$validator" --root "$1" >/dev/null; }
run_fail() { local expected="$1"; local target="$2"; set +e; output=$("$validator" --root "$target" 2>&1); status=$?; set -e; [ "$status" -ne 0 ] && grep -Fq "$expected" <<<"$output"; }
run_ok "$root"
run_ok "$root/tests/fixtures/adrs/valid"
run_fail ADR002 "$root/tests/fixtures/adrs/invalid-id"
run_fail ADR004 "$root/tests/fixtures/adrs/missing-outcome"
run_fail ADR006 "$root/tests/fixtures/adrs/duplicate-scope"
run_fail ADR008 "$root/tests/fixtures/adrs/verified-missing-evidence"
echo validate_adrs_contract_ok
