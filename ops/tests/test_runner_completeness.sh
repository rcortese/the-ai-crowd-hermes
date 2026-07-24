#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
runner=$root/ops/tests/run-moss-release-tests.sh
manifest=$root/ops/tests/package_a_required_suites.txt
fail(){ printf 'runner-completeness: RED %s\n' "$*" >&2; exit 1; }
[[ -x $runner ]] || fail 'runner is not executable'
[[ -f $manifest ]] || fail 'required suite manifest missing'
mapfile -t required < <(sed '/^[[:space:]]*#/d;/^[[:space:]]*$/d' "$manifest")
((${#required[@]} > 0)) || fail 'empty required suite manifest'
if grep -Eq 'NOT_IMPLEMENTED|product-behavior-cases' "$runner"; then
  fail 'canonical runner contains an unimplemented release gate'
fi
run_trace(){ local candidate=$1 trace=$2; : >"$trace"; HDDT_RUNNER_ROOT="$root" HDDT_RUNNER_TRACE_FILE="$trace" HDDT_RUNNER_TRACE_ONLY=1 bash "$candidate"; }
check_candidate(){
  local candidate=$1 label=$2 trace=$3
  run_trace "$candidate" "$trace" || fail "$label runner execution failed"
  mapfile -t seen <"$trace"
  for i in "${!required[@]}"; do if [[ ${seen[$i]:-} != "${required[$i]}" ]]; then printf "runner-completeness: RED %s missing suite: %s\n" "$label" "${required[$i]}" >&2; return 1; fi; done
  if ((${#seen[@]} != ${#required[@]})); then printf "runner-completeness: RED %s unexpected dispatch count\n" "$label" >&2; return 1; fi
}
if [[ ${1:-} == --self-check ]]; then
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/hddt-runner-oracle.XXXXXX"); trap 'rm -rf "$tmp"' EXIT
  check_candidate "$runner" canonical "$tmp/canonical.trace" || fail "canonical runner incomplete"
  printf '%s\n' 'runner-completeness: SELF_CHECK PASS independent-manifest trace=PASS'; exit 0
fi
tmp=$(mktemp -d "${TMPDIR:-/tmp}/hddt-runner-oracle.XXXXXX"); trap 'rm -rf "$tmp"' EXIT
check_candidate "$runner" canonical "$tmp/canonical.trace" || fail "canonical runner incomplete"
printf '%s\n' 'runner-completeness: canonical PASS'
for mutant in build deploy-decoupling; do
  candidate="$tmp/runner-$mutant.sh"; cp "$runner" "$candidate"
  token='dispatch build bash ops/tests/test_moss_candidate_build_contract.sh "$root"'
  if [[ $mutant == deploy-decoupling ]]; then token='dispatch deploy-decoupling bash ops/tests/test_moss_deploy_decoupling.sh "$root"'; fi
  TOKEN="$token" perl -0pi -e 'BEGIN {$t=$ENV{TOKEN}} if (s/\Q$t\E/# omitted by package-A omission mutant/ != 1) { die "mutant setup token count != 1\n" }' "$candidate"
  if check_candidate "$candidate" "$mutant-omission" "$tmp/$mutant.trace" 2>"$tmp/$mutant.err"; then fail "$mutant omission mutant was accepted"; fi
  grep -Fq "missing suite: $mutant" "$tmp/$mutant.err" || { cat "$tmp/$mutant.err" >&2; fail "$mutant omission did not fail by exact suite name"; }
  printf 'runner-completeness: omission RED suite=%s\n' "$mutant"
done
printf '%s\n' 'runner-completeness: PASS canonical=trace omission-mutants=2'
