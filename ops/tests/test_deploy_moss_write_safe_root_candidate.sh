#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
runner="$repo/ops/scripts/deploy-moss-write-safe-root-candidate.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
if "$runner" >"$tmp/noargs" 2>&1; then echo 'no-args unexpectedly succeeded' >&2; exit 1; fi
"$runner" --help >"$tmp/help"
grep -q 'Usage:' "$tmp/help"
for phase in preflight build validate promote; do
  "$runner" --commit deadbeef --phase "$phase"
  test "$(cat "$repo/ops/candidates/write-safe-root-deadbeef/status")" = "dry-run $phase"
done
if "$runner" --commit deadbeef --phase nope >"$tmp/bad" 2>&1; then echo 'bad phase unexpectedly succeeded' >&2; exit 1; fi
rm -rf "$repo/ops/candidates/write-safe-root-deadbeef"
echo runner_contract_ok
