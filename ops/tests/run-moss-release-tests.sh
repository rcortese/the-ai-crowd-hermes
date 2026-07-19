#!/usr/bin/env bash
# Canonical source-only runner. It invokes fixtures only; no Docker lifecycle.
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$root"
bash ops/tests/test_moss_candidate_build_contract.py "$root"
bash ops/tests/test_validate_moss_release_binding.sh
bash ops/tests/test_hddt_moss.sh
bash ops/tests/test_hddt_moss_recovery.sh
bash ops/tests/test_hddt_mutations.sh
printf '%s\n' 'moss-release-tests: PASS suites=build,binding,hddt,recovery,mutations'
