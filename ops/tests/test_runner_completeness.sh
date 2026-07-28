#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
runner=$root/ops/tests/run-moss-release-tests.sh
manifest=$root/ops/tests/package_a_required_suites.txt
independent_required=(closure compose-rollback)
fail(){ printf 'runner-completeness: RED %s\n' "$*" >&2; exit 1; }
[[ -x $runner ]] || fail 'runner is not executable'
[[ -f $manifest ]] || fail 'required suite manifest missing'
if grep -Eq 'NOT_IMPLEMENTED|product-behavior-cases' "$runner"; then
  fail 'canonical runner contains an unimplemented release gate'
fi
read_required(){
 local candidate_manifest=$1
 [[ -f $candidate_manifest ]] || return 1
 mapfile -t required < <(sed '/^[[:space:]]*#/d;/^[[:space:]]*$/d' "$candidate_manifest")
 ((${#required[@]} > 0)) || return 1
}
run_trace(){ local candidate=$1 trace=$2; : >"$trace"; HDDT_RUNNER_ROOT="$root" HDDT_RUNNER_TRACE_FILE="$trace" HDDT_RUNNER_TRACE_ONLY=1 bash "$candidate"; }
check_candidate(){
 local candidate=$1 label=$2 trace=$3 candidate_manifest=${4:-$manifest} suite found
 local -a required=() seen=()
 read_required "$candidate_manifest" || { printf 'runner-completeness: RED %s required suite manifest invalid\n' "$label" >&2; return 1; }
 run_trace "$candidate" "$trace" || { printf 'runner-completeness: RED %s runner execution failed\n' "$label" >&2; return 1; }
 mapfile -t seen <"$trace"
 for i in "${!required[@]}"; do if [[ ${seen[$i]:-} != "${required[$i]}" ]]; then printf "runner-completeness: RED %s missing suite: %s\n" "$label" "${required[$i]}" >&2; return 1; fi; done
 if ((${#seen[@]} != ${#required[@]})); then printf "runner-completeness: RED %s unexpected dispatch count\n" "$label" >&2; return 1; fi
 for suite in "${independent_required[@]}"; do
  found=0
  for i in "${seen[@]}"; do [[ $i == "$suite" ]] && { found=1; break; }; done
  ((found)) || { printf "runner-completeness: RED %s missing suite: %s\n" "$label" "$suite" >&2; return 1; }
 done
}
if [[ ${1:-} == --self-check ]]; then
 tmp=$(mktemp -d "${TMPDIR:-/tmp}/hddt-runner-oracle.XXXXXX"); trap 'rm -rf "$tmp"' EXIT
 check_candidate "$runner" canonical "$tmp/canonical.trace" "$manifest" || fail "canonical runner incomplete"
 printf '%s\n' 'runner-completeness: SELF_CHECK PASS independent-closure trace=PASS'; exit 0
fi
tmp=$(mktemp -d "${TMPDIR:-/tmp}/hddt-runner-oracle.XXXXXX"); trap 'rm -rf "$tmp"' EXIT
check_candidate "$runner" canonical "$tmp/canonical.trace" "$manifest" || fail "canonical runner incomplete"
printf '%s\n' 'runner-completeness: canonical PASS'
for mutant in build deploy-decoupling closure compose-rollback; do
 candidate="$tmp/runner-$mutant.sh"; candidate_manifest=$manifest; cp "$runner" "$candidate"
 token='dispatch build bash ops/tests/test_moss_candidate_build_contract.sh "$root"'
 if [[ $mutant == deploy-decoupling ]]; then token='dispatch deploy-decoupling bash ops/tests/test_moss_deploy_decoupling.sh "$root"'; fi
 if [[ $mutant == closure ]]; then
  token='dispatch closure bash ops/tests/test_moss_release_source_closure.sh'
  candidate_manifest="$tmp/required-without-closure.txt"
  grep -Fvx closure "$manifest" >"$candidate_manifest"
 fi
 if [[ $mutant == compose-rollback ]]; then
  token='dispatch compose-rollback bash ops/tests/test_hddt_moss.sh compose-rollback'
  candidate_manifest="$tmp/required-without-compose-rollback.txt"
  grep -Fvx compose-rollback "$manifest" >"$candidate_manifest"
 fi
 TOKEN="$token" perl -0pi -e 'BEGIN {$t=$ENV{TOKEN}} if (s/\Q$t\E/# omitted by package-A omission mutant/ != 1) { die "mutant setup token count != 1\n" }' "$candidate"
 if check_candidate "$candidate" "$mutant-omission" "$tmp/$mutant.trace" "$candidate_manifest" 2>"$tmp/$mutant.err"; then fail "$mutant omission mutant was accepted"; fi
 grep -Fq "missing suite: $mutant" "$tmp/$mutant.err" || { cat "$tmp/$mutant.err" >&2; fail "$mutant omission did not fail by exact suite name"; }
 printf 'runner-completeness: omission RED suite=%s\n' "$mutant"
done
printf '%s\n' 'runner-completeness: PASS canonical=trace omission-mutants=4 independent=closure,compose-rollback'
