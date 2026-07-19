#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$root"
name="hddt-rehearsal-python-tests-$$"
docker run --rm --name "$name" --network none -v "$root:/src:ro" -w /src python:3.13-alpine python3 ops/tests/test_moss_candidate_build_contract.py /src
bash ops/tests/test_validate_moss_release_binding.sh
bash ops/tests/test_hddt_moss.sh
bash ops/tests/test_hddt_moss_recovery.sh
printf '%s\n' 'moss-release-tests: PASS'
