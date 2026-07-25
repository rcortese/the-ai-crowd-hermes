#!/usr/bin/env bash
# Independent membership oracle for the release-source closure manifest.
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
closure=${HDDT_CLOSURE_SCRIPT:-$root/ops/scripts/lib/hddt-moss-closure.sh}
manifest=$root/ops/manifests/moss-release-source-closure.paths
fail(){ printf 'closure-membership: RED %s\n' "$*" >&2; exit 1; }
[[ -x $closure && -f $manifest ]] || fail 'closure oracle inputs unavailable'
mapfile -t required <<'REQUIRED_CLOSURE_PATHS'
compose.yaml
ops/manifests/moss-release-source-closure.paths
ops/scripts/build-moss-all-in-one-candidate.sh
ops/scripts/hddt-moss-launcher.sh
ops/scripts/hddt-moss.sh
ops/scripts/lib/hddt-moss-closure.sh
ops/scripts/validate-moss-release-binding.sh
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
ops/tests/test_moss_title_topic_contract.sh
ops/tests/test_package_a.sh
ops/tests/test_runner_completeness.sh
ops/tests/test_validate_moss_release_binding.sh
tests/smoke-deploy.sh
REQUIRED_CLOSURE_PATHS
assert_oracle(){
 local candidate=$1
 bash -c 'source "$1"; hddt_required_source_closure "$2"' _ "$closure" "$candidate"
}
assert_oracle "$manifest" || fail 'canonical manifest rejected'
tmp=$(mktemp -d "${TMPDIR:-/tmp}/moss-closure-membership.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
for path in "${required[@]}"; do
 candidate="$tmp/$(basename "$path")"
 grep -Fvx -- "$path" "$manifest" >"$candidate"
 if assert_oracle "$candidate"; then fail "omission accepted: $path"; fi
done
if [[ ${MOSS_CLOSURE_ORACLE_MUTANT_CHILD:-0} != 1 ]]; then
 mutant="$tmp/hddt-moss-closure-mutant.sh"
 cp -- "$closure" "$mutant"
 perl -0pi -e 's/^compose\.yaml\n//m' "$mutant"
 set +e
 MOSS_CLOSURE_ORACLE_MUTANT_CHILD=1 HDDT_CLOSURE_SCRIPT="$mutant" bash "$0" >"$tmp/mutant.out" 2>&1
 rc=$?
 set -e
 [[ $rc != 0 ]] || fail 'required-membership mutant survived'
 grep -Fq 'omission accepted: compose.yaml' "$tmp/mutant.out" || fail 'required-membership mutant lacked causal oracle'
fi
printf 'closure-membership: PASS canonical=required omissions=RED count=%s mutant=RED\n' "${#required[@]}"
