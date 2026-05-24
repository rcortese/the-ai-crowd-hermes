#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
smoke="$repo_root/bin/jen-todoist-smoke-test"
mock_dir=$(mktemp -d)
mock_read="$mock_dir/jen-task-read"
canonical_runtime="$repo_root/memory/heartbeat-state.json"
canonical_observation="$repo_root/.local/state/todoist-observation-snapshot.json"
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
    echo "assertion failed: $message (expected $expected got $actual)" >&2
    exit 1
  fi
}

cat > "$mock_read" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
mode="${JEN_SMOKE_MOCK_MODE:-ok}"
printf '%s|runtime=%s|observation=%s\n' "$*" "${JEN_TASK_RUNTIME_STATE_FILE:-}" "${JEN_TODOIST_OBSERVATION_STATE_FILE:-}" >> "$(dirname "$0")/calls.log"
case "$1" in
  activity-log)
    case "$mode" in
      ok|diff_degraded)
        jq -nc '{contract_version:"jen-task-runtime.v1",command:"read-activity-log",status:"ok",events:[],summary:{activity_event_count:0},complete:true}'
        ;;
      activity_partial)
        jq -nc '{contract_version:"jen-task-runtime.v1",command:"read-activity-log",status:"failed",failure_class:"request_failure",limitations:["activity_log_plan_dependent"]}'
        exit 1
        ;;
      activity_request_fail)
        jq -nc '{contract_version:"jen-task-runtime.v1",command:"read-activity-log",status:"failed",failure_class:"request_failure",limitations:[]}'
        exit 1
        ;;
      auth_fail)
        jq -nc '{contract_version:"jen-task-runtime.v1",command:"read-activity-log",status:"failed",failure_class:"auth_failure"}'
        exit 1
        ;;
      provider_bad)
        jq -nc '{contract_version:"jen-task-runtime.v1",command:"read-activity-log",status:"failed",failure_class:"provider_shape_invalid"}'
        exit 1
        ;;
      network_fail)
        jq -nc '{contract_version:"jen-task-runtime.v1",command:"read-activity-log",status:"failed",failure_class:"network_failure"}'
        exit 1
        ;;
      *) exit 9 ;;
    esac
    ;;
  ensure-observation-baseline)
    jq -nc '{contract_version:"jen-task-runtime.v1",command:"ensure-observation-baseline",status:"ok",refreshed:true,complete:true}'
    ;;
  recent-diff)
    case "$mode" in
      diff_degraded)
        jq -nc '{contract_version:"jen-task-runtime.v1",command:"read-recent-diff",status:"degraded",coverage_status:"none",complete:true}'
        ;;
      *)
        jq -nc '{contract_version:"jen-task-runtime.v1",command:"read-recent-diff",status:"ok",coverage_status:"net_observation_baseline_before_since",complete:true}'
        ;;
    esac
    ;;
  recent-activity)
    jq -nc '{contract_version:"jen-task-runtime.v1",command:"read-recent-activity",status:"ok",tasks:[],summary:{activity_task_count:0},complete:true}'
    ;;
  *)
    jq -nc --arg got "$1" '{status:"failed",failure_class:"unexpected_command",got:$got}'
    exit 1
    ;;
esac
MOCK
chmod +x "$mock_read"

run_smoke() {
  env JEN_TODOIST_SMOKE_TASK_READ="$mock_read" JEN_TODOIST_SMOKE_NOW_UTC=2026-04-27T04:30:00Z "$smoke" "$@"
}

json=$(JEN_SMOKE_MOCK_MODE=ok run_smoke --since 2026-04-27T03:30:00Z --until 2026-04-27T04:30:00Z --limit 50)
assert_jq "$json" '.contract_version == "jen-todoist-smoke-test.v1" and .status == "ok" and .cleanup_result == "ok" and .isolation.runtime_state == "temp" and .isolation.observation_state == "temp"' 'ok smoke shape'
assert_jq "$json" '(.components | length) == 4 and all(.components[]; .contract_valid == true)' 'components are contract valid'
assert_jq "$json" '.isolation.canonical_runtime_touched == false and .isolation.canonical_observation_touched == false' 'canonical state not touched flags'
if grep -F "$canonical_runtime" "$mock_dir/calls.log" || grep -F "$canonical_observation" "$mock_dir/calls.log"; then
  echo 'assertion failed: smoke passed canonical state path to wrapper' >&2
  cat "$mock_dir/calls.log" >&2
  exit 1
fi

json=$(JEN_SMOKE_MOCK_MODE=diff_degraded run_smoke --since 2026-04-27T03:30:00Z --until 2026-04-27T04:30:00Z --limit 50)
assert_jq "$json" '.status == "ok" and (.components[] | select(.name == "recent-diff") | .status == "degraded")' 'recent-diff degraded is acceptable smoke success'

json=$(JEN_SMOKE_MOCK_MODE=activity_partial run_smoke --since 2026-04-27T03:30:00Z --until 2026-04-27T04:30:00Z --limit 50)
assert_jq "$json" '.status == "partial" and (.warnings | index("activity_log_unavailable_or_plan_limited"))' 'activity log partial exits zero with warning'

set +e
request_fail_json=$(JEN_SMOKE_MOCK_MODE=activity_request_fail run_smoke --since 2026-04-27T03:30:00Z --until 2026-04-27T04:30:00Z --limit 50)
request_fail_status=$?
set -e
assert_eq "$request_fail_status" "1" 'generic activity-log request failure exits nonzero'
assert_jq "$request_fail_json" '.status == "failed" and .failure_class == "request_failure"' 'generic request failure shape'

set +e
fail_json=$(JEN_SMOKE_MOCK_MODE=auth_fail run_smoke --since 2026-04-27T03:30:00Z --until 2026-04-27T04:30:00Z --limit 50)
fail_status=$?
set -e
assert_eq "$fail_status" "1" 'auth failure exits nonzero'
assert_jq "$fail_json" '.status == "failed" and .failure_class == "auth_failure"' 'auth failure shape'

set +e
bad_provider=$(JEN_SMOKE_MOCK_MODE=provider_bad run_smoke --since 2026-04-27T03:30:00Z --until 2026-04-27T04:30:00Z --limit 50)
bad_provider_status=$?
set -e
assert_eq "$bad_provider_status" "1" 'provider shape exits nonzero'
assert_jq "$bad_provider" '.status == "failed" and .failure_class == "provider_shape_invalid"' 'provider shape failure'

set +e
bad_arg=$(run_smoke --since nope)
bad_arg_status=$?
set -e
assert_eq "$bad_arg_status" "1" 'invalid arg exits nonzero'
assert_jq "$bad_arg" '.status == "failed" and .failure_class == "invalid_argument"' 'invalid arg shape'

rg -q 'JEN_TASK_RUNTIME_STATE_FILE=.*mktemp|SMOKE_RUNTIME_STATE' "$smoke" || { echo 'assertion failed: smoke must use temp runtime state' >&2; exit 1; }

echo 'ok - jen-todoist-smoke-test contract behavior'
