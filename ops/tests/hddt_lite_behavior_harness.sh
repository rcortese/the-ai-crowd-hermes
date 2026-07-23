#!/usr/bin/env bash
set -Eeuo pipefail
json_case='{"case_id":"schema-1","operation":"automatic","expected":"REJECTED_PRE_APPLY"}'
parse_case(){
  [[ $(jq -r 'keys|join(",")' <<<"$1") == 'case_id,expected,operation' ]] || { printf '%s\n' 'case schema keys invalid' >&2; return 1; }
  jq -e 'all(.[]; type == "string" and length > 0)' >/dev/null <<<"$1"
}
result(){ jq -cn --arg id "$1" --arg status "$2" --arg reason "$3" '{case_id:$id,status:$status,effects:{docker_calls:[],ledger:[],created_paths:[],consumed_ready:false},reason:$reason}'; }
self_test(){
  parse_case "$json_case"
  local fx ready ledger='[]'; fx=$(mktemp -d "${TMPDIR:-/tmp}/hddt-package-a.XXXXXX"); ready=$fx/operation.ready
  trap 'rm -rf "$fx"' RETURN
  printf '%s' sealed >"$ready"
  [[ -f $ready && $ledger == '[]' ]] || return 1
  [[ $(result automatic-rejection NOT_IMPLEMENTED 'reserved for package B') == *'"consumed_ready":false'* ]] || return 1
  rm -rf "$fx"; trap - RETURN
  [[ ! -e $fx ]] || return 1
  printf '%s\n' 'hddt-behavior-harness: SELF_TEST PASS schema=isolation ledger=PASS zero-effect=PASS cleanup=PASS'
}
if [[ ${1:-} == --self-test ]]; then self_test; exit; fi
result automatic-rejection NOT_IMPLEMENTED 'package B'
result launcher-handshake NOT_IMPLEMENTED 'package C'
result third-state-recovery NOT_IMPLEMENTED 'package C'
printf '%s\n' 'hddt-behavior-harness: RED NOT_IMPLEMENTED product-behavior-cases=3'
exit 1
