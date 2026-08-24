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
dispatch build bash ops/tests/test_moss_candidate_build_contract.sh "$root"
dispatch roy-all-in-one /opt/hermes/.venv/bin/python ops/tests/test_roy_all_in_one_candidate_contract.py "$root"
dispatch roy-webui-api-server /opt/hermes/.venv/bin/python ops/tests/test_roy_webui_api_server_archive_contract.py "$root"
dispatch deploy-decoupling bash ops/tests/test_moss_deploy_decoupling.sh "$root"
dispatch smoke-contract bash ops/tests/test_moss_candidate_smoke_contract.sh "$root"
dispatch supervisor-api-key bash ops/tests/test_moss_supervisor_api_key_contract.sh "$root"
dispatch binding bash ops/tests/test_validate_moss_release_binding.sh
dispatch closure bash ops/tests/test_moss_release_source_closure.sh
dispatch bootstrap bash ops/tests/test_bootstrap_hddt_moss_root.sh
dispatch hddt bash ops/tests/test_hddt_moss.sh
dispatch recovery bash ops/tests/test_hddt_moss_recovery.sh
dispatch cas bash ops/tests/test_hddt_moss.sh cas
dispatch signals bash ops/tests/test_hddt_moss.sh signals
dispatch control bash ops/tests/test_hddt_moss.sh control
dispatch oracles bash ops/tests/test_hddt_moss.sh oracles
dispatch compose-rollback bash ops/tests/test_hddt_moss.sh compose-rollback
dispatch adapter bash ops/tests/test_hddt_adapter.sh
dispatch mutations bash ops/tests/test_hddt_mutations.sh
printf '%s\n' 'moss-release-tests: PASS suites=package-a,build,roy-all-in-one,roy-webui-api-server,deploy-decoupling,smoke-contract,supervisor-api-key,binding,closure,bootstrap,hddt,recovery,cas,signals,control,oracles,compose-rollback,adapter,mutations T01-T87'
