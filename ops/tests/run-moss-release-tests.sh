#!/usr/bin/env bash
# Canonical source-only runner. It invokes fixtures only; no Docker lifecycle.
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$root"
expected=(
  'bash ops/tests/test_moss_candidate_build_contract.sh "$root"'
  'bash ops/tests/test_validate_moss_release_binding.sh'
  'bash ops/tests/test_hddt_moss.sh'
  'bash ops/tests/test_hddt_moss_recovery.sh'
  'bash ops/tests/test_hddt_moss.sh cas'
  'bash ops/tests/test_hddt_moss.sh signals'
  'bash ops/tests/test_hddt_moss.sh control'
  'bash ops/tests/test_hddt_moss.sh oracles'
  'bash ops/tests/test_hddt_adapter.sh'
  'bash ops/tests/test_hddt_mutations.sh'
)
if [[ ${HDDT_RUNNER_SELF_CHECK:-0} == 1 ]]; then
  for invocation in "${expected[@]}"; do grep -Fx -- "$invocation" "$0" >/dev/null || { printf 'runner omitted: %s\n' "$invocation" >&2; exit 65; }; done
  printf '%s\n' 'moss-release-tests: SELF_CHECK PASS'; exit 0
fi
bash ops/tests/test_moss_candidate_build_contract.sh "$root"
bash ops/tests/test_validate_moss_release_binding.sh
bash ops/tests/test_hddt_moss.sh
bash ops/tests/test_hddt_moss_recovery.sh
bash ops/tests/test_hddt_moss.sh cas
bash ops/tests/test_hddt_moss.sh signals
bash ops/tests/test_hddt_moss.sh control
bash ops/tests/test_hddt_moss.sh oracles
bash ops/tests/test_hddt_adapter.sh
bash ops/tests/test_hddt_mutations.sh
printf '%s\n' 'moss-release-tests: PASS suites=build,binding,hddt,recovery,cas,signals,control,oracles,adapter,mutations T01-T81'
