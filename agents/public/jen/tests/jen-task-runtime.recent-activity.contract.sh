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
printf '%s\n' "$*" >> "${JEN_RECENT_ACTIVITY_ADAPTER_LOG:?}"
mode="${JEN_RECENT_ACTIVITY_MODE:-success}"
case "$mode" in
  success)
    jq -nc '{results:[
      {id:"inside",content:"Edited task",project_id:"p1",labels:["HomeLab"],due:{date:"2026-04-27"},priority:4,updated_at:"2026-04-26T20:15:00Z"},
      {id:"missing",content:"No timestamp",project_id:"p1",labels:null,due:null,priority:1,updated_at:null}
    ],next_cursor:null,complete:true,page_count:1}'
    ;;
  incomplete)
    jq -nc '{results:[{id:"inside",content:"Edited task",updated_at:"2026-04-26T20:15:00Z"}],next_cursor:"cursor",complete:false,page_count:1}'
    ;;
  badshape)
    jq -nc '{items:[]}'
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
  JEN_RECENT_ACTIVITY_ADAPTER_LOG="$adapter_log"
)

json=$(env "${common_env[@]}" "$runtime" read-recent-activity --since 2026-04-26T19:00:00Z --until 2026-04-26T21:00:00Z --limit 50)
assert_jq "$json" '.contract_version == "jen-task-runtime.v1" and .command == "read-recent-activity" and .status == "ok" and .source == "live" and .provenance == "live-active-updated-window" and .evidence_level == "current-active-updated-at" and .complete == true' 'recent activity success shape'
assert_jq "$json" '.tasks | length == 1' 'runtime keeps only active tasks with updated_at inside the requested window'
assert_jq "$json" '.tasks[0].id == "inside" and .tasks[0].labels == ["HomeLab"]' 'runtime normalizes matching activity tasks'
assert_jq "$json" '.limitations | index("field_level_diff_unavailable_without_task_body_cache")' 'limitations include no field-level diff'
assert_eq "$(cat "$adapter_log")" "active-updated-window 2026-04-26T19:00:00Z 2026-04-26T21:00:00Z 50" 'adapter boundary command'
assert_jq "$(cat "$state_file")" '.todoist.runtime.read_recent_activity.last_activity_window.count == 1 and .todoist.runtime.read_recent_activity.last_activity_window.since == "2026-04-26T19:00:00Z"' 'runtime stores observation metadata only'

set +e
missing_since=$(env "${common_env[@]}" "$runtime" read-recent-activity --until 2026-04-26T21:00:00Z)
missing_since_status=$?
set -e
assert_eq "$missing_since_status" "1" 'missing since exits nonzero'
assert_jq "$missing_since" '.status == "failed" and .failure_class == "invalid_argument"' 'missing since failure shape'

set +e
bad_window=$(env "${common_env[@]}" "$runtime" read-recent-activity --since 2026-04-26T22:00:00Z --until 2026-04-26T21:00:00Z)
bad_window_status=$?
set -e
assert_eq "$bad_window_status" "1" 'since after until exits nonzero'
assert_jq "$bad_window" '.status == "failed" and .failure_class == "invalid_argument"' 'since after until failure shape'

set +e
bad_limit=$(env "${common_env[@]}" "$runtime" read-recent-activity --since 2026-04-26T19:00:00Z --limit 201)
bad_limit_status=$?
set -e
assert_eq "$bad_limit_status" "1" 'invalid limit exits nonzero'
assert_jq "$bad_limit" '.status == "failed" and .failure_class == "invalid_argument"' 'invalid limit failure shape'

set +e
incomplete=$(env "${common_env[@]}" JEN_RECENT_ACTIVITY_MODE=incomplete "$runtime" read-recent-activity --since 2026-04-26T19:00:00Z --until 2026-04-26T21:00:00Z)
incomplete_status=$?
set -e
assert_eq "$incomplete_status" "1" 'incomplete provider window fails closed'
assert_jq "$incomplete" '.status == "failed" and .failure_class == "provider_shape_invalid"' 'incomplete failure shape'

set +e
badshape=$(env "${common_env[@]}" JEN_RECENT_ACTIVITY_MODE=badshape "$runtime" read-recent-activity --since 2026-04-26T19:00:00Z --until 2026-04-26T21:00:00Z)
badshape_status=$?
set -e
assert_eq "$badshape_status" "1" 'bad shape exits nonzero'
assert_jq "$badshape" '.status == "failed" and .failure_class == "provider_shape_invalid"' 'bad shape failure'

set +e
failed=$(env "${common_env[@]}" JEN_RECENT_ACTIVITY_MODE=fail "$runtime" read-recent-activity --since 2026-04-26T19:00:00Z --until 2026-04-26T21:00:00Z)
failed_status=$?
set -e
assert_eq "$failed_status" "1" 'adapter failure exits nonzero'
assert_jq "$failed" '.status == "failed" and .failure_class == "network_failure"' 'adapter failure class'

echo 'ok - jen-task-runtime recent-activity behavior'
