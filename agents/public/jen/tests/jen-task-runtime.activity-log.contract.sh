#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
runtime="$repo_root/bin/jen-task-runtime"
mock_dir=$(mktemp -d)
state_file="$mock_dir/state.json"
mock_adapter="$mock_dir/todoist-api.sh"
adapter_log="$mock_dir/adapter.log"
trap 'rm -rf "$mock_dir"' EXIT

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

cat > "$mock_adapter" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${JEN_ACTIVITY_LOG_ADAPTER_LOG:?}"
mode="${JEN_ACTIVITY_LOG_MODE:-success}"
case "$mode" in
  success)
    jq -nc '{results:[
      {id:"evt1",event_type:"updated",object_event_type:"item:updated",object_type:"item",object_id:"task1",parent_project_id:"p1",event_date:"2026-04-26T20:15:00Z",extra_data:{content:"Edited task"}},
      {id:"evt2",event_type:"moved",object_event_type:"item:moved",object_type:"item",object_id:"task2",parent_project_id:"p2",event_date:"2026-04-26T20:25:00Z"}
    ],next_cursor:null,complete:true,page_count:1}'
    ;;
  incomplete)
    jq -nc '{results:[{id:"evt1",event_type:"updated",object_type:"item"}],next_cursor:"cursor",complete:false,page_count:1}'
    ;;
  badshape)
    jq -nc '{items:[]}'
    ;;
  forbidden)
    jq -nc '{error:"auth_failure",status:403}' >&2
    exit 4
    ;;
  silent_fail)
    exit 3
    ;;
  fail)
    jq -nc '{error:"network_failure"}' >&2
    exit 3
    ;;
  *) exit 9 ;;
esac
MOCK
chmod +x "$mock_adapter"

common_env=(
  JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_adapter"
  JEN_TASK_RUNTIME_STATE_FILE="$state_file"
  JEN_ACTIVITY_LOG_ADAPTER_LOG="$adapter_log"
)

json=$(env "${common_env[@]}" "$runtime" read-activity-log --since 2026-04-26T19:00:00Z --until 2026-04-26T21:00:00Z --limit 50)
assert_jq "$json" '.contract_version == "jen-task-runtime.v1" and .command == "read-activity-log" and .status == "ok" and .source == "live" and .provenance == "live-activity-log-window" and .evidence_level == "provider-activity-log" and .complete == true' 'activity log success shape'
assert_jq "$json" '.events | length == 2' 'runtime returns normalized activity events'
assert_jq "$json" '.events[0].object_id == "task1" and .events[0].extra_data.content == "Edited task"' 'runtime normalizes event fields'
assert_jq "$json" '(.limitations | index("activity_log_plan_dependent")) and (.limitations | index("before_after_values_not_guaranteed"))' 'limitations include provider constraints'
assert_eq "$(cat "$adapter_log")" "activity-window 2026-04-26T19:00:00Z 2026-04-26T21:00:00Z 50" 'adapter boundary command'
assert_jq "$(cat "$state_file")" '.todoist.runtime.read_activity_log.last_activity_window.count == 2 and .todoist.runtime.read_activity_log.last_activity_window.since == "2026-04-26T19:00:00Z"' 'runtime stores observation metadata only'

set +e
missing_since=$(env "${common_env[@]}" "$runtime" read-activity-log --until 2026-04-26T21:00:00Z)
missing_since_status=$?
set -e
assert_eq "$missing_since_status" "1" 'missing since exits nonzero'
assert_jq "$missing_since" '.status == "failed" and .failure_class == "invalid_argument"' 'missing since failure shape'

set +e
bad_window=$(env "${common_env[@]}" "$runtime" read-activity-log --since 2026-04-26T22:00:00Z --until 2026-04-26T21:00:00Z)
bad_window_status=$?
set -e
assert_eq "$bad_window_status" "1" 'since after until exits nonzero'
assert_jq "$bad_window" '.status == "failed" and .failure_class == "invalid_argument"' 'since after until failure shape'

set +e
bad_limit=$(env "${common_env[@]}" "$runtime" read-activity-log --since 2026-04-26T19:00:00Z --limit 101)
bad_limit_status=$?
set -e
assert_eq "$bad_limit_status" "1" 'invalid limit exits nonzero'
assert_jq "$bad_limit" '.status == "failed" and .failure_class == "invalid_argument"' 'invalid limit failure shape'

set +e
incomplete=$(env "${common_env[@]}" JEN_ACTIVITY_LOG_MODE=incomplete "$runtime" read-activity-log --since 2026-04-26T19:00:00Z --until 2026-04-26T21:00:00Z)
incomplete_status=$?
set -e
assert_eq "$incomplete_status" "1" 'incomplete provider window fails closed'
assert_jq "$incomplete" '.status == "failed" and .failure_class == "provider_shape_invalid"' 'incomplete failure shape'

set +e
badshape=$(env "${common_env[@]}" JEN_ACTIVITY_LOG_MODE=badshape "$runtime" read-activity-log --since 2026-04-26T19:00:00Z --until 2026-04-26T21:00:00Z)
badshape_status=$?
set -e
assert_eq "$badshape_status" "1" 'bad shape exits nonzero'
assert_jq "$badshape" '.status == "failed" and .failure_class == "provider_shape_invalid"' 'bad shape failure'

set +e
forbidden=$(env "${common_env[@]}" JEN_ACTIVITY_LOG_MODE=forbidden "$runtime" read-activity-log --since 2026-04-26T19:00:00Z --until 2026-04-26T21:00:00Z)
forbidden_status=$?
set -e
assert_eq "$forbidden_status" "1" 'forbidden provider exits nonzero'
assert_jq "$forbidden" '.status == "failed" and .failure_class == "auth_failure"' 'forbidden failure class'

set +e
silent_failed=$(env "${common_env[@]}" JEN_ACTIVITY_LOG_MODE=silent_fail "$runtime" read-activity-log --since 2026-04-26T19:00:00Z --until 2026-04-26T21:00:00Z)
silent_failed_status=$?
set -e
assert_eq "$silent_failed_status" "1" 'silent adapter failure exits nonzero'
assert_jq "$silent_failed" '.status == "failed" and .failure_class == "network_failure"' 'silent adapter failure class uses captured nonzero status'

set +e
failed=$(env "${common_env[@]}" JEN_ACTIVITY_LOG_MODE=fail "$runtime" read-activity-log --since 2026-04-26T19:00:00Z --until 2026-04-26T21:00:00Z)
failed_status=$?
set -e
assert_eq "$failed_status" "1" 'adapter failure exits nonzero'
assert_jq "$failed" '.status == "failed" and .failure_class == "network_failure"' 'adapter failure class'

echo 'ok - jen-task-runtime activity-log behavior'
