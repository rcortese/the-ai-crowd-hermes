#!/usr/bin/env bash
set -Eeuo pipefail
hddt_required_source_closure(){
 local manifest=${1:?release source closure manifest required}
 [[ -f $manifest && ! -L $manifest ]] || return 65
 local -a expected=()
 mapfile -t expected <<'REQUIRED_CLOSURE_PATHS'
compose.yaml
ops/build-inputs/moss-clash-royale-war-bot.sha256
ops/cron/the-ai-crowd-hddt-retention.cron
ops/hermes-webui-overrides/moss-title-topic-priority.patch
ops/images/Dockerfile.moss-all-in-one
ops/manifests/moss-release-source-closure.paths
ops/scripts/build-moss-all-in-one-candidate.sh
ops/scripts/hddt-moss-launcher.sh
ops/scripts/hddt-moss-status.sh
ops/scripts/hddt-moss.sh
ops/scripts/lib/hddt-moss-closure.sh
ops/scripts/validate-moss-native-conversation.sh
ops/scripts/validate-moss-release-binding.sh
ops/supervisor/moss-all-in-one-supervisord.conf
ops/tests/hddt_lite_behavior_harness.sh
ops/tests/package_a_required_suites.txt
ops/tests/run-moss-release-tests.sh
ops/tests/test_hddt_adapter.sh
ops/tests/test_hddt_lite_behavior.sh
ops/tests/test_hddt_lite_contract.sh
ops/tests/test_hddt_lite_mutants.sh
ops/tests/test_hddt_lite_mutations.sh
ops/tests/test_hddt_moss.sh
ops/tests/test_hddt_moss_recovery.sh
ops/tests/test_hddt_mutations.sh
ops/tests/test_moss_candidate_build_contract.sh
ops/tests/test_moss_candidate_smoke_contract.sh
ops/tests/test_moss_deploy_decoupling.sh
ops/tests/test_moss_release_source_closure.sh
ops/tests/test_moss_supervisor_api_key_contract.sh
ops/tests/test_moss_title_topic_contract.sh
ops/tests/test_package_a.sh
ops/tests/test_runner_completeness.sh
ops/tests/test_validate_moss_release_binding.sh
tests/smoke-deploy.sh
REQUIRED_CLOSURE_PATHS
 ((${#expected[@]} == 35)) || return 65
 cmp -s <(printf '%s\n' "${expected[@]}") <(LC_ALL=C sort "$manifest") || return 65
}
hddt_source_closure(){
 local root=${1:?release source required} manifest="$1/ops/manifests/moss-release-source-closure.paths" git_bin=${HDDT_GIT_BIN:-git}
 [[ -d $root && ! -L $root && -f $manifest && ! -L $manifest ]] || return 65
 local -a paths=() path; mapfile -t paths <"$manifest"; ((${#paths[@]} > 0)) || return 65
 LC_ALL=C sort -cu "$manifest" >/dev/null || return 65
 hddt_required_source_closure "$manifest" || return 65
 for path in "${paths[@]}"; do [[ -n $path && $path != /* && $path != *..* ]] || return 65; "$git_bin" -c safe.directory="$root" -C "$root" ls-files --error-unmatch -- "$path" >/dev/null || return 65; done
 "$git_bin" -c safe.directory="$root" -C "$root" ls-tree -r --full-tree HEAD -- "${paths[@]}" | sha256sum | cut -d' ' -f1
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then hddt_source_closure "${1:?release source required}"; fi
