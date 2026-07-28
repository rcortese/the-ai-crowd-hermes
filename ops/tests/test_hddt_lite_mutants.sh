#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
if [[ ${1:-} == --self-test ]]; then exec "$root/ops/tests/hddt_lite_behavior_harness.sh" --self-test; fi
printf '%s\n' 'hddt-lite-mutants: NOT_IMPLEMENTED package-A schema-only; causal mutants reserved for D2' >&2
exit 1
