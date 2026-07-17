#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
runtime="$repo_root/bin/jen-task-runtime"
state_file=$(mktemp)
mock_dir=$(mktemp -d)
mock_script="$mock_dir/todoist-api.sh"
idem_dir=$(mktemp -d)
call_log="$mock_dir/calls.log"
cleanup() { rm -f "$state_file"; rm -rf "$mock_dir" "$idem_dir"; }
trap cleanup EXIT

assert_jq() {
  local json="$1" filter="$2" message="$3"
  jq -e "$filter" <<<"$json" >/dev/null || { echo "assertion failed: $message" >&2; echo "$json" >&2; exit 1; }
}
assert_eq() {
  local actual="$1" expected="$2" message="$3"
  [[ "$actual" == "$expected" ]] || { echo "assertion failed: $message" >&2; echo "expected: $expected" >&2; echo "actual: $actual" >&2; exit 1; }
}

cat > "$mock_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"; shift || true
printf '%s %s\n' "$cmd" "$*" >> "${JEN_PARENT_MOVE_TEST_LOG:-/dev/null}"
mode="${JEN_PARENT_MOVE_TEST_MODE:-success}"
if [[ "$cmd" == task ]]; then
  id="$1"
  if [[ "$mode" == missing_parent && "$id" == parent-1 ]]; then printf '{"error":"not_found"}\n' >&2; exit 4; fi
  project_id=project-1
  [[ "$mode" == different_project && "$id" == parent-1 ]] && project_id=other-project
  parent_id=null
  [[ "$mode" == already_parent && "$id" == child-1 ]] && parent_id='"parent-1"'
  task=$(jq -nc --arg id "$id" --arg project_id "$project_id" --argjson parent_id "$parent_id" '{id:$id,content:"Task",project_id:$project_id,section_id:null,parent_id:$parent_id,labels:["ctx"],due:null,deadline:null,priority:2,updated_at:"2026-07-17T12:00:00Z"}')
  if [[ "$mode" == child_missing_project && "$id" == child-1 ]] || [[ "$mode" == parent_missing_project && "$id" == parent-1 ]]; then
    jq -c 'del(.project_id)' <<<"$task"
  else
    printf '%s\n' "$task"
  fi
  exit 0
fi
case "$mode:$cmd" in
  success:move-task-parent)
    jq -nc --arg id "$1" --arg parent_id "$2" '{id:$id,content:"Move me",project_id:"project-1",parent_id:$parent_id}' ;;
  fail_move:move-task-parent) printf '{"error":"network_failure"}\n' >&2; exit 3 ;;
  wrong_parent:move-task-parent) jq -nc --arg id "$1" '{id:$id,parent_id:"unexpected-parent"}' ;;
  wrong_id:move-task-parent) jq -nc --arg parent_id "$2" '{id:"unexpected-child",parent_id:$parent_id}' ;;
  malformed:move-task-parent) printf 'not-json\n' ;;
  *) printf '{"error":"unexpected"}\n' >&2; exit 9 ;;
esac
EOF
chmod +x "$mock_script"

success=$(JEN_IDEMPOTENCY_DIR="$idem_dir/success" JEN_PARENT_MOVE_TEST_LOG="$call_log" JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" TODOIST_API_TOKEN=dummy "$runtime" move-task-parent --task-id child-1 --parent-id parent-1)
assert_jq "$success" '.status == "ok" and .command == "move-task-parent" and .operation == "move-task-parent" and .verified == true and .parent_id == "parent-1" and .task.id == "child-1" and .task.parent_id == "parent-1"' 'parent move success contract'
assert_jq "$success" '.mutation.gateway_plan.mutation_payload.parent_id == "parent-1" and .mutation.gateway_plan.preview.fields_changed == ["parent_id"]' 'parent move gateway plan'
assert_eq "$(cat "$call_log")" $'task child-1\ntask parent-1\nmove-task-parent child-1 parent-1' 'parent move validates child and parent then writes once'

: > "$call_log"
replay=$(JEN_IDEMPOTENCY_DIR="$idem_dir/success" JEN_PARENT_MOVE_TEST_MODE=already_parent JEN_PARENT_MOVE_TEST_LOG="$call_log" JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" TODOIST_API_TOKEN=dummy "$runtime" move-task-parent --task-id child-1 --parent-id parent-1)
assert_jq "$replay" '.status == "ok" and .verified == true and .task.parent_id == "parent-1" and .mutation.gateway_plan.mutation_payload.parent_id == "parent-1" and .mutation.idempotency.check_status == "duplicate" and .mutation.idempotency.decision == "duplicate_verified"' 'verified retry is explicitly reported as duplicate_verified despite changed pre-state'
assert_eq "$(grep -c '^move-task-parent ' "$call_log" || true)" 0 'verified retry performs no write'

: > "$call_log"
already=$(JEN_IDEMPOTENCY_DIR="$idem_dir/already" JEN_PARENT_MOVE_TEST_MODE=already_parent JEN_PARENT_MOVE_TEST_LOG="$call_log" JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" TODOIST_API_TOKEN=dummy "$runtime" move-task-parent --task-id child-1 --parent-id parent-1)
assert_jq "$already" '.status == "ok" and .verified == true and .idempotent == true and .task.parent_id == "parent-1" and .mutation.gateway_plan.mutation_payload.parent_id == "parent-1" and .mutation.idempotency.check_status == "miss"' 'pre-existing relation is recorded through the mutation gateway'
assert_eq "$(grep -c '^move-task-parent ' "$call_log" || true)" 0 'pre-existing relation performs no write'

for args in '--task-id child-1' '--task-id child-1 --parent-id child-1'; do
  : > "$call_log"; set +e
  output=$(JEN_PARENT_MOVE_TEST_LOG="$call_log" JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" TODOIST_API_TOKEN=dummy "$runtime" move-task-parent $args)
  status=$?; set -e
  assert_eq "$status" 1 'invalid relation fails closed'
  assert_jq "$output" '.status == "failed" and .failure_class == "invalid_argument"' 'invalid relation failure shape'
  [[ "$args" != *'parent-id child-1'* ]] || assert_eq "$(wc -l < "$call_log")" 0 'self-parent fails before adapter access'
done

for pair in 'missing_parent request_failure' 'different_project invalid_argument' 'child_missing_project invalid_argument' 'parent_missing_project invalid_argument' 'fail_move network_failure' 'wrong_parent verification_failed' 'wrong_id verification_failed' 'malformed verification_failed'; do
  set -- $pair; mode="$1"; expected="$2"; : > "$call_log"; set +e
  output=$(JEN_IDEMPOTENCY_DIR="$idem_dir/$mode" JEN_PARENT_MOVE_TEST_MODE="$mode" JEN_PARENT_MOVE_TEST_LOG="$call_log" JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" TODOIST_API_TOKEN=dummy "$runtime" move-task-parent --task-id child-1 --parent-task-id parent-1)
  status=$?; set -e
  assert_eq "$status" 1 "$mode exits non-zero"
  assert_jq "$output" ".status == \"failed\" and .failure_class == \"$expected\"" "$mode failure class"
done

decision_helper="$mock_dir/decision-helper.sh"
cat > "$decision_helper" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${JEN_PARENT_DECISION}" in
  blocked) failure=blocked ;;
  awaiting_confirmation) failure=awaiting_confirmation ;;
  collision) failure=collision ;;
  unsafe_replay_state) failure=unsafe_replay_state ;;
  retry_partial) failure=retry_partial ;;
esac
jq -nc --arg decision "$failure" '{decision:$decision,gateway_plan:{idempotency_key:"gate",normalized_hash:"h",risk_level:"high"},idempotency:{check_status:"miss",record:null}}'
EOF
chmod +x "$decision_helper"

for pair in 'blocked mutation_blocked' 'awaiting_confirmation mutation_confirmation_required' 'collision idempotency_collision' 'unsafe_replay_state unsafe_replay_state' 'retry_partial unsafe_replay_state'; do
  set -- $pair; decision="$1"; expected="$2"; : > "$call_log"; set +e
  output=$(JEN_TASK_RUNTIME_MUTATION_HELPER="$decision_helper" JEN_PARENT_DECISION="$decision" JEN_PARENT_MOVE_TEST_LOG="$call_log" JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" TODOIST_API_TOKEN=dummy "$runtime" move-task-parent --task-id child-1 --parent-id parent-1)
  status=$?; set -e
  assert_eq "$status" 1 "$decision should fail closed"
  assert_jq "$output" ".status == \"failed\" and .failure_class == \"$expected\"" "$decision failure class"
  assert_eq "$(grep -c '^move-task-parent ' "$call_log" || true)" 0 "$decision performs no adapter write"
done

echo "jen-task-runtime-move-task-parent-contract: ok"
