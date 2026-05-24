#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
helper="$repo_root/bin/jen-todoist-self-heal"
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

assert_jq() {
  local json="$1" filter="$2" message="$3"
  if ! jq -e "$filter" <<<"$json" >/dev/null; then
    echo "assertion failed: $message" >&2
    echo "$json" >&2
    exit 1
  fi
}

make_runtime() {
  local path="$1" mode="$2"
  cat > "$path" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
mode="${JEN_SELF_HEAL_TEST_MODE:-ok}"
log="${JEN_SELF_HEAL_TEST_LOG:-/dev/null}"
echo "$mode $*" >> "$log"
case "$mode" in
  ok)
    case "${1:-}" in
      health) jq -nc '{contract_version:"jen-task-runtime.v1",command:"health",status:"ok",posture:"available",token_status:"set"}' ;;
      read-active) jq -nc '{contract_version:"jen-task-runtime.v1",command:"read-active",status:"ok",source:"live",tasks:[{id:"t1",content:"ok"}]}' ;;
      read-recent-completed) jq -nc '{contract_version:"jen-task-runtime.v1",command:"read-recent-completed",status:"ok",source:"live",tasks:[],summary:{completed_task_count:0},complete:true}' ;;
      *) jq -nc '{status:"failed",failure_class:"invalid_argument"}'; exit 2 ;;
    esac
    ;;
  transient_then_ok)
    marker="${JEN_SELF_HEAL_TEST_MARKER:?marker required}"
    if [[ ! -f "$marker" ]]; then
      : > "$marker"
      jq -nc '{contract_version:"jen-task-runtime.v1",command:"read-active",status:"failed",failure_class:"network_failure"}'
      exit 3
    fi
    jq -nc '{contract_version:"jen-task-runtime.v1",command:"read-active",status:"ok",source:"live",tasks:[{id:"t2",content:"retry ok"}]}'
    ;;
  transient_fail)
    printf '{"error":"rate_limited","token":"abc123abc123abc123abc123abc123abc123"}\n' >&2
    jq -nc '{contract_version:"jen-task-runtime.v1",command:"read-active",status:"failed",failure_class:"rate_limited"}'
    exit 3
    ;;
  runtime_config)
    printf 'TODOIST_API_TOKEN=abc123abc123abc123abc123abc123abc123 adapter returned invalid json\n' >&2
    printf 'not-json-token-abc123abc123abc123abc123abc123abc123\n'
    exit 0
    ;;
  credential)
    printf '{"error":"auth_failure","Authorization":"Bearer abc123abc123abc123abc123abc123abc123"}\n' >&2
    jq -nc '{contract_version:"jen-task-runtime.v1",command:"read-active",status:"failed",failure_class:"auth_failure"}'
    exit 2
    ;;
  *) exit 99 ;;
esac
MOCK
  chmod +x "$path"
}

runtime="$tmpdir/mock-runtime"
log="$tmpdir/attempts.log"
state="$tmpdir/state.json"
handoff="$tmpdir/handoff.json"
make_runtime "$runtime" ok

out=$(JEN_SELF_HEAL_TEST_MODE=ok JEN_SELF_HEAL_TEST_LOG="$log" "$helper" health --runtime "$runtime" --state-file "$state")
assert_jq "$out" '.status == "ok"' 'health ok status'
assert_jq "$out" '.verification_state == "health Todoist ok via caminho canônico; escrita não testada"' 'health fixed-state wording'
assert_jq "$(cat "$state")" '.live_write_tested == false and .verification_state == "health Todoist ok via caminho canônico; escrita não testada"' 'durable health verification state'

: > "$log"
rm -f "$tmpdir/marker"
out=$(JEN_SELF_HEAL_TEST_MODE=transient_then_ok JEN_SELF_HEAL_TEST_MARKER="$tmpdir/marker" JEN_SELF_HEAL_TEST_LOG="$log" "$helper" read-active --runtime "$runtime" --state-file "$state" --max-retries 2)
assert_jq "$out" '.status == "ok" and .attempt_count == 2' 'transient retry succeeds on second attempt'
assert_jq "$out" '.verification_state == "captura/leitura verificada no Todoist; pode chamar de corrigido"' 'read fixed-state wording'
if [[ $(wc -l < "$log") -ne 2 ]]; then
  echo "assertion failed: expected exactly two transient attempts" >&2
  cat "$log" >&2
  exit 1
fi

set +e
out=$(JEN_SELF_HEAL_TEST_MODE=transient_fail JEN_SELF_HEAL_TEST_LOG="$log" "$helper" read-active --runtime "$runtime" --state-file "$state" --max-retries 2 --pending-item 'capturar token abc123abc123abc123abc123abc123abc123' --handoff-file "$handoff")
rc=$?
set -e
[[ $rc -eq 1 ]] || { echo "assertion failed: transient unresolved exits 1" >&2; echo "$out" >&2; exit 1; }
assert_jq "$out" '.status == "unresolved" and .failure_group == "transient" and .attempt_count == 3' 'transient unresolved classification and retry limit'
assert_jq "$out" '.incident.requested_moss_action == "Restore the already-approved Todoist integration through Jen'"'"'s canonical runtime path."' 'transient Moss restore request'
assert_jq "$out" '.incident.runtime_output_summary.stderr | contains("[REDACTED]")' 'stderr redacted'
if grep -q 'abc123abc123abc123abc123abc123abc123' "$handoff"; then
  echo "assertion failed: handoff leaked raw token" >&2
  cat "$handoff" >&2
  exit 1
fi
assert_jq "$(cat "$handoff")" '.fixed_state_vocabulary | index("runtime restaurado; verificação pendente")' 'runtime restored vocabulary present'

set +e
out=$(JEN_SELF_HEAL_TEST_MODE=runtime_config JEN_SELF_HEAL_TEST_LOG="$log" "$helper" read-active --runtime "$runtime" --state-file "$state" --max-retries 2 --pending-item 'pending item')
rc=$?
set -e
[[ $rc -eq 1 ]] || { echo "assertion failed: runtime/config exits 1" >&2; echo "$out" >&2; exit 1; }
assert_jq "$out" '.status == "unresolved" and .failure_group == "runtime/config" and .attempt_count == 1' 'runtime/config no retry'
assert_jq "$out" '.incident.runtime_output_summary.runtime_absent == false and .incident.runtime_output_summary.command_failed == false' 'runtime/config payload command state'
if grep -q 'abc123abc123abc123abc123abc123abc123' <<<"$out"; then
  echo "assertion failed: runtime/config output leaked raw token" >&2
  echo "$out" >&2
  exit 1
fi

set +e
out=$(JEN_SELF_HEAL_TEST_MODE=credential JEN_SELF_HEAL_TEST_LOG="$log" "$helper" read-active --runtime "$runtime" --state-file "$state" --max-retries 2)
rc=$?
set -e
[[ $rc -eq 2 ]] || { echo "assertion failed: credential/auth exits 2" >&2; echo "$out" >&2; exit 1; }
assert_jq "$out" '.status == "blocked" and .failure_group == "credential/auth" and .attempt_count == 1' 'credential/auth blocks without retry'
assert_jq "$out" '.incident.human_authorization_required == true' 'credential/auth requires human'
assert_jq "$out" '.incident.requested_moss_action | contains("Human authorization required")' 'credential/auth does not ask Moss to repair credentials'

set +e
out=$("$helper" read-active --runtime "$tmpdir/missing-runtime" --state-file "$state")
rc=$?
set -e
[[ $rc -eq 1 ]] || { echo "assertion failed: absent runtime exits 1" >&2; echo "$out" >&2; exit 1; }
assert_jq "$out" '.failure_group == "runtime/config" and .incident.runtime_output_summary.runtime_absent == true' 'absent runtime classified runtime/config'

echo 'jen-todoist-self-heal contract tests passed'
