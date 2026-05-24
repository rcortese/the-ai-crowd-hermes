#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
runtime="$repo_root/bin/jen-task-runtime"
state_file=$(mktemp)
mock_dir=$(mktemp -d)
mock_script="$mock_dir/todoist-api.sh"
idem_dir=$(mktemp -d)
call_log="$mock_dir/calls.log"

cleanup() {
  rm -f "$state_file"
  rm -rf "$mock_dir" "$idem_dir"
}
trap cleanup EXIT

assert_jq() {
  local json="$1" filter="$2" message="$3"
  if ! jq -e "$filter" <<<"$json" >/dev/null; then
    echo "assertion failed: $message" >&2
    echo "$json" >&2
    exit 1
  fi
}

assert_eq() {
  local actual="$1" expected="$2" message="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "assertion failed: $message" >&2
    echo "expected: $expected" >&2
    echo "actual:   $actual" >&2
    exit 1
  fi
}

cat > "$mock_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
shift || true
printf '%s %s\n' "$cmd" "$*" >> "${JEN_MOVE_TEST_LOG:-/dev/null}"
case "${JEN_MOVE_TEST_MODE:-success}:$cmd" in
  success:task)
    task_id="$1"
    jq -nc --arg id "$task_id" '{id:$id,content:"Move me",description:null,project_id:"source-project",section_id:null,parent_id:null,labels:["ctx"],due:{date:"2026-05-12"},deadline:{date:"2026-05-15"},priority:2,updated_at:"2026-05-11T20:00:00Z"}'
    ;;
  success:move-task)
    task_id="$1"
    project_id="$2"
    jq -nc --arg id "$task_id" --arg project_id "$project_id" '{id:$id,content:"Move me",description:null,project_id:$project_id,section_id:null,parent_id:null,labels:["ctx"],due:{date:"2026-05-12"},deadline:{date:"2026-05-15"},priority:2,updated_at:"2026-05-11T20:01:00Z"}'
    ;;
  fail_move:task)
    task_id="$1"
    jq -nc --arg id "$task_id" '{id:$id,content:"Move me",project_id:"source-project"}'
    ;;
  fail_move:move-task)
    printf '{"error":"network_failure"}\n' >&2
    exit 3
    ;;
  wrong_project:task)
    task_id="$1"
    jq -nc --arg id "$task_id" '{id:$id,content:"Move me",project_id:"source-project"}'
    ;;
  wrong_project:move-task)
    task_id="$1"
    jq -nc --arg id "$task_id" '{id:$id,content:"Move me",project_id:"unexpected-project"}'
    ;;
  missing_task:task)
    printf '{"error":"not_found"}\n' >&2
    exit 4
    ;;
  *)
    jq -nc --arg mode "${JEN_MOVE_TEST_MODE:-success}" --arg cmd "$cmd" '{error:"unexpected",mode:$mode,cmd:$cmd}' >&2
    exit 9
    ;;
esac
EOF
chmod +x "$mock_script"

move_json=$(JEN_IDEMPOTENCY_DIR="$idem_dir/move" JEN_MOVE_TEST_LOG="$call_log" JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" TODOIST_API_TOKEN=dummy "$runtime" move-task --task-id task-1 --project-id target-project)
assert_jq "$move_json" '.contract_version == "jen-task-runtime.v1" and .command == "move-task" and .status == "ok" and .operation == "move-task" and .verified == true' 'move-task success contract shape'
assert_jq "$move_json" '.project_id == "target-project" and .task.project_id == "target-project"' 'move-task returns verified target project/list'
assert_jq "$move_json" '.task.due.date == "2026-05-12" and .task.deadline.date == "2026-05-15"' 'move-task preserves due/deadline task fields in returned task'
assert_jq "$move_json" '.mutation.gateway_plan.target_system == "todoist" and .mutation.gateway_plan.canonical_object_type == "task" and .mutation.gateway_plan.mutation_payload.project_id == "target-project"' 'move-task passes through mutation gateway'
assert_jq "$move_json" '.mutation.gateway_plan.preview.fields_changed == ["project_id"]' 'move-task previews project_id-only change'
assert_eq "$(cat "$call_log")" $'task task-1\nmove-task task-1 target-project' 'move-task reads pre-state then calls adapter move only'

alias_json=$(JEN_IDEMPOTENCY_DIR="$idem_dir/list-alias" JEN_MOVE_TEST_LOG=/dev/null JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" TODOIST_API_TOKEN=dummy "$runtime" move-task --task-id task-2 --list-id list-project)
assert_jq "$alias_json" '.status == "ok" and .project_id == "list-project" and .task.project_id == "list-project"' '--list-id aliases Todoist project/list target'

set +e
invalid_json=$(JEN_IDEMPOTENCY_DIR="$idem_dir/invalid" JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" TODOIST_API_TOKEN=dummy "$runtime" move-task --task-id task-1)
invalid_status=$?
set -e
assert_eq "$invalid_status" "1" 'missing project/list target fails closed'
assert_jq "$invalid_json" '.command == "move-task" and .status == "failed" and .failure_class == "invalid_argument"' 'invalid move-task failure shape'

set +e
fail_json=$(JEN_IDEMPOTENCY_DIR="$idem_dir/fail" JEN_MOVE_TEST_MODE=fail_move JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" TODOIST_API_TOKEN=dummy "$runtime" move-task --task-id task-1 --project-id target-project)
fail_status=$?
set -e
assert_eq "$fail_status" "1" 'adapter move failure exits non-zero'
assert_jq "$fail_json" '.command == "move-task" and .status == "failed" and .failure_class == "network_failure"' 'adapter move failure shape'

set +e
wrong_project_json=$(JEN_IDEMPOTENCY_DIR="$idem_dir/wrong-project" JEN_MOVE_TEST_MODE=wrong_project JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" TODOIST_API_TOKEN=dummy "$runtime" move-task --task-id task-1 --project-id target-project)
wrong_project_status=$?
set -e
assert_eq "$wrong_project_status" "1" 'adapter wrong-project result exits non-zero'
assert_jq "$wrong_project_json" '.command == "move-task" and .status == "failed" and .failure_class == "verification_failed"' 'wrong project result fails verification'

echo "jen-task-runtime-move-task-contract: ok"
