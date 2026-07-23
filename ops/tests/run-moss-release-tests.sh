#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
root=${HDDT_RUNNER_ROOT:-$root}
cd "$root"
dispatch() {
  local suite=$1; shift
  if [[ -n ${HDDT_RUNNER_TRACE_FILE:-} ]]; then printf '%s\n' "$suite" >>"$HDDT_RUNNER_TRACE_FILE"; fi
  [[ ${HDDT_RUNNER_TRACE_ONLY:-0} == 1 ]] && return 0
  "$@"
}
if [[ ${HDDT_RUNNER_SELF_CHECK:-0} == 1 ]]; then exec bash ops/tests/test_runner_completeness.sh --self-check; fi
dispatch hddt-lite-behavior bash ops/tests/test_hddt_lite_behavior.sh
dispatch hddt-lite-mutants bash ops/tests/test_hddt_lite_mutants.sh
dispatch build bash ops/tests/test_moss_candidate_build_contract.sh "$root"
dispatch deploy-decoupling bash ops/tests/test_moss_deploy_decoupling.sh "$root"
dispatch smoke-contract bash ops/tests/test_moss_candidate_smoke_contract.sh "$root"
dispatch title-topic bash ops/tests/test_moss_title_topic_contract.sh "$root"
dispatch binding bash ops/tests/test_validate_moss_release_binding.sh
dispatch hddt bash ops/tests/test_hddt_moss.sh
dispatch recovery bash ops/tests/test_hddt_moss_recovery.sh
dispatch cas bash ops/tests/test_hddt_moss.sh cas
dispatch signals bash ops/tests/test_hddt_moss.sh signals
dispatch control bash ops/tests/test_hddt_moss.sh control
dispatch oracles bash ops/tests/test_hddt_moss.sh oracles
dispatch adapter bash ops/tests/test_hddt_adapter.sh
dispatch mutations bash ops/tests/test_hddt_mutations.sh
printf '%s\n' 'moss-release-tests: PASS suites=package-a-lite,build,deploy-decoupling,smoke-contract,title-topic,binding,hddt,recovery,cas,signals,control,oracles,adapter,mutations T01-T83'
