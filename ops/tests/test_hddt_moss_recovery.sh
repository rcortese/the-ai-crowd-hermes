#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.."&&pwd)
exec bash "$root/ops/tests/test_hddt_moss.sh" recovery
