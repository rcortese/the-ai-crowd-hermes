#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
loop="$repo_root/bin/jen-todoist-interaction-loop"
mock_dir=$(mktemp -d)
mock_runtime="$mock_dir/jen-task-runtime"
mock_due_semantics="$mock_dir/jen-todoist-due-semantics"
call_log="$mock_dir/calls.log"
semantics_call_log="$mock_dir/semantics-calls.log"
FAKE_SECRET="FAKE_TODOIST_TOKEN_SHOULD_BE_REDACTED"

cleanup() {
  rm -rf "$mock_dir"
}
trap cleanup EXIT

assert_jq() {
  local json="$1"
  local filter="$2"
  local message="$3"
  if ! jq -e "$filter" <<<"$json" >/dev/null; then
    echo "assertion failed: $message" >&2
    echo "$json" >&2
    exit 1
  fi
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local message="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "assertion failed: $message" >&2
    echo "expected: $expected" >&2
    echo "actual:   $actual" >&2
    exit 1
  fi
}

assert_nonempty_output() {
  local output="$1"
  local message="$2"
  [[ -n "$output" ]] || {
    echo "assertion failed: $message" >&2
    exit 1
  }
}

assert_no_secret() {
  local output="$1"
  local message="$2"
  if grep -Fq "$FAKE_SECRET" <<<"$output"; then
    echo "assertion failed: $message" >&2
    echo "$output" >&2
    exit 1
  fi
}

assert_single_json_object() {
  local json="$1"
  local message="$2"
  assert_nonempty_output "$json" "$message"
  assert_jq "$json" 'type == "object"' "$message"
}

assert_enum_member() {
  local value="$1"
  local message="$2"
  shift 2
  local allowed
  for allowed in "$@"; do
    if [[ "$value" == "$allowed" ]]; then
      return 0
    fi
  done
  echo "assertion failed: $message" >&2
  echo "unexpected value: $value" >&2
  exit 1
}

assert_envelope() {
  local json="$1"
  local message="$2"
  assert_single_json_object "$json" "$message"
  assert_enum_member "$(jq -r '.result // empty' <<<"$json")" "$message result enum" changed no_change partial failed
  assert_enum_member "$(jq -r '.failure_class // empty' <<<"$json")" "$message failure_class enum" none ambiguity policy_blocked technical_failure privacy_redaction
  assert_enum_member "$(jq -r '.jen_action // empty' <<<"$json")" "$message jen_action enum" acknowledge_changed acknowledge_no_change ask_user_clarification explain_policy_boundary stop_and_handoff_to_moss
  assert_jq "$json" '.operator_message | type == "string" and length > 0' "$message operator_message present"
  assert_no_secret "$json" "$message secret leakage"
}

assert_has_handoff() {
  local json="$1"
  local message="$2"
  local handoff_id
  handoff_id="$(jq -r '.handoff_id // empty' <<<"$json")"
  [[ -n "$handoff_id" ]] || {
    echo "assertion failed: $message" >&2
    echo "$json" >&2
    exit 1
  }
}

assert_no_handoff() {
  local json="$1"
  local message="$2"
  local handoff_id
  handoff_id="$(jq -r '.handoff_id // empty' <<<"$json")"
  [[ -z "$handoff_id" ]] || {
    echo "assertion failed: $message" >&2
    echo "$json" >&2
    exit 1
  }
}

cat > "$mock_runtime" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${JEN_TODOIST_LOOP_TEST_CALL_LOG:?}"
mode="${JEN_TODOIST_LOOP_TEST_MODE:-success}"
cmd="${1:-}"
shift || true
case "$mode:$cmd" in
  success:read-recent-completed)
    jq -nc '{contract_version:"jen-task-runtime.v1",command:"read-recent-completed",status:"ok",source:"live",summary:{baseline_present:true,delta_completed_items_total:2,observed_bucket_count:1}}'
    ;;
  success:classify-interaction-signals)
    jq -nc '{contract_version:"jen-task-runtime.v1",command:"classify-interaction-signals",status:"ok",source:"runtime-metadata",signals:[{signal_id:"runtime-completion-delta:2026-04-24T12:00:00Z",level:"aggregated",requires_user_interruption:false}],summary:{signal_count:1,attention_worthy_count:0,action_eligible_count:0},complete:true}'
    ;;
  due_fail:read-recent-completed|due_fail:classify-interaction-signals|completion_fail:classify-interaction-signals)
    JEN_TODOIST_LOOP_TEST_MODE=success "$0" "$cmd" "$@"
    ;;
  completion_fail:read-recent-completed)
    jq -nc '{contract_version:"jen-task-runtime.v1",command:"read-recent-completed",status:"failed",failure_class:"network_failure"}'
    exit 1
    ;;
  observational_recent_due_fail:read-recent-completed|observational_recent_due_skipped:read-recent-completed)
    jq -nc '{contract_version:"jen-task-runtime.v1",command:"read-recent-completed",status:"degraded",source:"observational",provenance:"runtime-metadata-summary",summary:{baseline_present:true,delta_completed_items_total:1,observed_bucket_count:1}}'
    ;;
  observational_recent_due_fail:classify-interaction-signals|observational_recent_due_skipped:classify-interaction-signals)
    JEN_TODOIST_LOOP_TEST_MODE=success "$0" "$cmd" "$@"
    ;;
  all_fail:*)
    jq -nc --arg command "$cmd" '{contract_version:"jen-task-runtime.v1",command:$command,status:"failed",failure_class:"network_failure"}'
    exit 1
    ;;
  *)
    jq -nc --arg command "$cmd" '{contract_version:"jen-task-runtime.v1",command:$command,status:"failed",failure_class:"unexpected"}'
    exit 1
    ;;
esac
EOF
chmod +x "$mock_runtime"

cat > "$mock_due_semantics" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${JEN_TODOIST_LOOP_TEST_SEMANTICS_CALL_LOG:?}"
mode="${JEN_TODOIST_LOOP_TEST_MODE:-success}"
cmd="${1:-}"
shift || true
case "$mode:$cmd" in
  success:live-due-window|completion_fail:live-due-window)
    if [[ "$*" != "--from 2026-04-24 --to 2026-04-26" ]]; then
      jq -nc '{contract_version:"jen-todoist-due-semantics.v1",command:"live-due-window",status:"failed",failure_class:"unexpected_args",complete:false}'
      exit 1
    fi
    jq -nc '{contract_version:"jen-todoist-due-semantics.v1",command:"live-due-window",status:"ok",source:"live",from:"2026-04-24",to:"2026-04-26",summary:{task_count:1,category_counts:{soft_surface:1}},tasks:[{id:"due-1",content:"Due soon",due:{date:"2026-04-24",is_recurring:false},past_due_raw:false,classification:{category:"soft_surface",confidence:"medium",reason:"mock",suggested_action:"Keep it today, move it to `Esta Semana`, or remove the due date."},signals:["has_due_date"]}],complete:true}'
    ;;
  due_fail:live-due-window|observational_recent_due_fail:live-due-window)
    jq -nc '{contract_version:"jen-todoist-due-semantics.v1",command:"live-due-window",status:"failed",failure_class:"network_failure",complete:false}'
    exit 1
    ;;
  all_fail:*)
    jq -nc --arg command "$cmd" '{contract_version:"jen-todoist-due-semantics.v1",command:$command,status:"failed",failure_class:"network_failure",complete:false}'
    exit 1
    ;;
  *)
    jq -nc --arg command "$cmd" '{contract_version:"jen-todoist-due-semantics.v1",command:$command,status:"failed",failure_class:"unexpected",complete:false}'
    exit 1
    ;;
esac
EOF
chmod +x "$mock_due_semantics"

success_json=$(JEN_TODOIST_INTERACTION_LOOP_TASK_RUNTIME="$mock_runtime" JEN_TODOIST_INTERACTION_LOOP_DUE_SEMANTICS="$mock_due_semantics" JEN_TODOIST_LOOP_TEST_CALL_LOG="$call_log" JEN_TODOIST_LOOP_TEST_SEMANTICS_CALL_LOG="$semantics_call_log" "$loop" --from 2026-04-24 --to 2026-04-26)
assert_single_json_object "$success_json" 'success loop JSON output'
assert_jq "$success_json" '.status == "ok" and .complete == true' 'success loop shape'
assert_jq "$success_json" '.recent_completed.status == "ok" and .interaction_signals.status == "ok" and .due_pressure.status == "ok"' 'success components'
assert_jq "$success_json" '.due_pressure.output.tasks[0].content == "Due soon" and .due_pressure.output.tasks[0].classification.category == "soft_surface" and .due_pressure.output.summary.category_counts.soft_surface == 1' 'due live semantics appear in stdout'
assert_eq "$(sed -n '1p' "$call_log")" "read-recent-completed" 'first call recent completed'
assert_eq "$(sed -n '2p' "$call_log")" "classify-interaction-signals" 'second call classify signals'
assert_eq "$(wc -l < "$call_log" | tr -d ' ')" "2" 'loop does not call task runtime due window directly'
assert_eq "$(sed -n '1p' "$semantics_call_log")" "live-due-window --from 2026-04-24 --to 2026-04-26" 'due semantics helper called for due window'

: > "$call_log"
: > "$semantics_call_log"
skip_json=$(JEN_TODOIST_INTERACTION_LOOP_TASK_RUNTIME="$mock_runtime" JEN_TODOIST_INTERACTION_LOOP_DUE_SEMANTICS="$mock_due_semantics" JEN_TODOIST_LOOP_TEST_CALL_LOG="$call_log" JEN_TODOIST_LOOP_TEST_SEMANTICS_CALL_LOG="$semantics_call_log" "$loop" --from 2026-04-24 --to 2026-04-26 --no-due-window)
assert_single_json_object "$skip_json" 'skip loop JSON output'
assert_jq "$skip_json" '.status == "ok" and .due_pressure.status == "skipped" and .due_pressure.reason == "no_due_window"' 'no due window skip'
assert_eq "$(wc -l < "$call_log" | tr -d ' ')" "2" 'no due window avoids due call'
assert_eq "$(wc -l < "$semantics_call_log" | tr -d ' ')" "0" 'no due window avoids semantics helper call'

partial_due=$(JEN_TODOIST_INTERACTION_LOOP_TASK_RUNTIME="$mock_runtime" JEN_TODOIST_INTERACTION_LOOP_DUE_SEMANTICS="$mock_due_semantics" JEN_TODOIST_LOOP_TEST_CALL_LOG="$call_log" JEN_TODOIST_LOOP_TEST_SEMANTICS_CALL_LOG="$semantics_call_log" JEN_TODOIST_LOOP_TEST_MODE=due_fail "$loop" --from 2026-04-24 --to 2026-04-26)
assert_single_json_object "$partial_due" 'partial due JSON output'
assert_jq "$partial_due" '.status == "partial" and .complete == false and (.failures | length) == 1 and .failures[0].source == "due_pressure"' 'due failure partial'

partial_completion=$(JEN_TODOIST_INTERACTION_LOOP_TASK_RUNTIME="$mock_runtime" JEN_TODOIST_INTERACTION_LOOP_DUE_SEMANTICS="$mock_due_semantics" JEN_TODOIST_LOOP_TEST_CALL_LOG="$call_log" JEN_TODOIST_LOOP_TEST_SEMANTICS_CALL_LOG="$semantics_call_log" JEN_TODOIST_LOOP_TEST_MODE=completion_fail "$loop" --from 2026-04-24 --to 2026-04-26)
assert_single_json_object "$partial_completion" 'partial completion JSON output'
assert_jq "$partial_completion" '.status == "partial" and (.failures[] | select(.source == "recent_completed" and .failure_class == "network_failure"))' 'completion failure partial when due live succeeds'

set +e
observational_due_fail=$(JEN_TODOIST_INTERACTION_LOOP_TASK_RUNTIME="$mock_runtime" JEN_TODOIST_INTERACTION_LOOP_DUE_SEMANTICS="$mock_due_semantics" JEN_TODOIST_LOOP_TEST_CALL_LOG="$call_log" JEN_TODOIST_LOOP_TEST_SEMANTICS_CALL_LOG="$semantics_call_log" JEN_TODOIST_LOOP_TEST_MODE=observational_recent_due_fail "$loop" --from 2026-04-24 --to 2026-04-26)
observational_due_fail_status=$?
set -e
assert_eq "$observational_due_fail_status" "1" 'observational recent plus failed due exits nonzero'
assert_single_json_object "$observational_due_fail" 'observational due fail JSON output'
assert_jq "$observational_due_fail" '.status == "failed" and .recent_completed.output.status == "degraded" and .recent_completed.output.source == "observational"' 'observational recent does not count as live when due fails'

set +e
observational_due_skipped=$(JEN_TODOIST_INTERACTION_LOOP_TASK_RUNTIME="$mock_runtime" JEN_TODOIST_INTERACTION_LOOP_DUE_SEMANTICS="$mock_due_semantics" JEN_TODOIST_LOOP_TEST_CALL_LOG="$call_log" JEN_TODOIST_LOOP_TEST_SEMANTICS_CALL_LOG="$semantics_call_log" JEN_TODOIST_LOOP_TEST_MODE=observational_recent_due_skipped "$loop" --from 2026-04-24 --to 2026-04-26 --no-due-window)
observational_due_skipped_status=$?
set -e
assert_eq "$observational_due_skipped_status" "1" 'observational recent plus skipped due exits nonzero'
assert_single_json_object "$observational_due_skipped" 'observational due skipped JSON output'
assert_jq "$observational_due_skipped" '.status == "failed" and .due_pressure.status == "skipped"' 'observational recent does not count as live when due skipped'

set +e
failed_all=$(JEN_TODOIST_INTERACTION_LOOP_TASK_RUNTIME="$mock_runtime" JEN_TODOIST_INTERACTION_LOOP_DUE_SEMANTICS="$mock_due_semantics" JEN_TODOIST_LOOP_TEST_CALL_LOG="$call_log" JEN_TODOIST_LOOP_TEST_SEMANTICS_CALL_LOG="$semantics_call_log" JEN_TODOIST_LOOP_TEST_MODE=all_fail "$loop" --from 2026-04-24 --to 2026-04-26)
failed_all_status=$?
set -e
assert_eq "$failed_all_status" "1" 'all fail exits nonzero'
assert_single_json_object "$failed_all" 'all fail JSON output'
assert_jq "$failed_all" '.status == "failed" and .complete == false and (.failures | length) >= 2' 'all fail shape'

set +e
invalid_json=$(JEN_TODOIST_INTERACTION_LOOP_TASK_RUNTIME="$mock_runtime" JEN_TODOIST_INTERACTION_LOOP_DUE_SEMANTICS="$mock_due_semantics" "$loop" --from banana --to 2026-04-26)
invalid_status=$?
set -e
assert_eq "$invalid_status" "1" 'invalid args fail'
assert_single_json_object "$invalid_json" 'invalid args JSON output'
assert_jq "$invalid_json" '.status == "failed" and .failures[0].failure_class == "invalid_argument"' 'invalid args JSON'

if grep -q 'tools/todoist/todoist-api.sh' "$loop"; then
  echo 'assertion failed: todoist interaction loop calls raw todoist adapter' >&2
  exit 1
fi

set +e
canonical_not_a_task="$($loop --json --canonical-capture --dry-run --capture-input "$repo_root/tests/fixtures/canonical-capture/not-a-task.json" 2>&1)"
canonical_not_a_task_status=$?
set -e
assert_eq "$canonical_not_a_task_status" "0" 'canonical not-a-task should succeed'
assert_envelope "$canonical_not_a_task" 'canonical not-a-task envelope'
assert_jq "$canonical_not_a_task" '.result == "no_change" and .failure_class == "none" and .jen_action == "acknowledge_no_change"' 'canonical not-a-task semantic contract'
assert_no_handoff "$canonical_not_a_task" 'canonical not-a-task should not open handoff'

set +e
canonical_ambiguous="$($loop --json --canonical-capture --dry-run --capture-input "$repo_root/tests/fixtures/canonical-capture/ambiguous.json" 2>&1)"
canonical_ambiguous_status=$?
set -e
assert_eq "$canonical_ambiguous_status" "0" 'canonical ambiguity should succeed'
assert_envelope "$canonical_ambiguous" 'canonical ambiguous envelope'
assert_jq "$canonical_ambiguous" '.result == "no_change" and .failure_class == "ambiguity" and .jen_action == "ask_user_clarification"' 'canonical ambiguous semantic contract'
assert_no_handoff "$canonical_ambiguous" 'canonical ambiguity should not open handoff'

set +e
canonical_new="$($loop --json --canonical-capture --dry-run --capture-input "$repo_root/tests/fixtures/canonical-capture/canonical-new.json" 2>&1)"
canonical_new_status=$?
set -e
assert_eq "$canonical_new_status" "0" 'canonical new should succeed'
assert_envelope "$canonical_new" 'canonical new envelope'
assert_jq "$canonical_new" '.result == "changed" and .failure_class == "none" and .jen_action == "acknowledge_changed"' 'canonical new semantic contract'
assert_no_handoff "$canonical_new" 'canonical new should not open handoff'

set +e
canonical_reconcile="$($loop --json --canonical-capture --dry-run --capture-input "$repo_root/tests/fixtures/canonical-capture/canonical-reconcile.json" 2>&1)"
canonical_reconcile_status=$?
set -e
assert_eq "$canonical_reconcile_status" "0" 'canonical reconcile should succeed'
assert_envelope "$canonical_reconcile" 'canonical reconcile envelope'
assert_jq "$canonical_reconcile" '.result == "changed" and .failure_class == "none" and .jen_action == "acknowledge_changed"' 'canonical reconcile semantic contract'
assert_no_handoff "$canonical_reconcile" 'canonical reconcile should not open handoff'

set +e
canonical_technical_failure="$($loop --json --debug --canonical-capture --dry-run --capture-input "$repo_root/tests/fixtures/canonical-capture/technical-failure.json" 2>&1)"
canonical_technical_failure_status=$?
set -e
assert_eq "$canonical_technical_failure_status" "1" 'canonical technical failure exits nonzero'
assert_envelope "$canonical_technical_failure" 'canonical technical failure envelope'
assert_jq "$canonical_technical_failure" '.result == "failed" and .failure_class == "technical_failure" and .jen_action == "stop_and_handoff_to_moss"' 'canonical technical failure semantic contract'
assert_has_handoff "$canonical_technical_failure" 'canonical technical failure should emit handoff id'

set +e
redaction_debug="$($loop --json --verbose --debug --canonical-capture --dry-run --capture-input "$repo_root/tests/fixtures/canonical-capture/redaction-debug.json" 2>&1)"
redaction_debug_status=$?
set -e
assert_eq "$redaction_debug_status" "1" 'canonical redaction debug exits nonzero'
assert_envelope "$redaction_debug" 'canonical redaction debug envelope'
assert_jq "$redaction_debug" '.result == "failed" and .failure_class == "technical_failure" and .jen_action == "stop_and_handoff_to_moss"' 'canonical redaction debug semantic contract'
assert_has_handoff "$redaction_debug" 'canonical redaction debug should emit handoff id'
assert_no_secret "$redaction_debug" 'canonical redaction debug should not leak fake secret'

echo 'ok - jen-todoist-interaction-loop failure-standard contract tests'
