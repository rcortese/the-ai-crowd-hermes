#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
exec "$root/ops/tests/hddt_lite_behavior_harness.sh" "$@"
