#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$root"
python3 ops/tests/test_moss_candidate_build_contract.py "$root"
bash ops/tests/test_validate_moss_release_binding.sh
bash ops/tests/test_hddt_moss.sh
bash ops/tests/test_hddt_moss_recovery.sh
printf '%s\n' 'moss-release-tests: PASS'
