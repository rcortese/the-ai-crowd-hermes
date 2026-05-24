#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
wrapper="$repo_root/bin/jen-task-read"
mock_dir=$(mktemp -d)
trap 'rm -rf "$mock_dir"' EXIT

mock_runtime="$mock_dir/jen-task-runtime"
cat > "$mock_runtime" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '{"argv":['
first=1
for arg in "$@"; do
  if [[ "$first" -eq 0 ]]; then printf ','; fi
  first=0
  printf '%s' "$arg" | jq -R .
done
printf ']}'
MOCK
chmod +x "$mock_runtime"

assert_jq() {
  local json="$1" filter="$2" message="$3"
  if ! jq -e "$filter" <<<"$json" >/dev/null; then
    echo "assertion failed: $message" >&2
    echo "$json" >&2
    exit 1
  fi
}

assert_status() {
  local actual="$1" expected="$2" message="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "assertion failed: $message (expected $expected got $actual)" >&2
    exit 1
  fi
}

active=$(JEN_TASK_RUNTIME_BIN="$mock_runtime" "$wrapper" active)
assert_jq "$active" '.argv == ["read-active"]' 'active delegates to read-active'

due_window=$(JEN_TASK_RUNTIME_BIN="$mock_runtime" "$wrapper" due-window --from 2026-04-24 --to 2026-04-30)
assert_jq "$due_window" '.argv == ["read-due-window","--from","2026-04-24","--to","2026-04-30"]' 'due-window delegates with bounds'

recent_summary=$(JEN_TASK_RUNTIME_BIN="$mock_runtime" "$wrapper" recent-completed)
assert_jq "$recent_summary" '.argv == ["read-recent-completed"]' 'recent-completed summary delegates'

recent_tasks=$(JEN_TASK_RUNTIME_BIN="$mock_runtime" "$wrapper" recent-completed --tasks --since 2026-04-24T00:00:00Z --until 2026-04-25T00:00:00Z)
assert_jq "$recent_tasks" '.argv == ["read-recent-completed","--tasks","--since","2026-04-24T00:00:00Z","--until","2026-04-25T00:00:00Z"]' 'recent-completed tasks delegates with window'

recent_activity=$(JEN_TASK_RUNTIME_BIN="$mock_runtime" "$wrapper" recent-activity --since 2026-04-24T00:00:00Z --until 2026-04-25T00:00:00Z --limit 75)
assert_jq "$recent_activity" '.argv == ["read-recent-activity","--since","2026-04-24T00:00:00Z","--until","2026-04-25T00:00:00Z","--limit","75"]' 'recent-activity delegates with window and limit'

activity_log=$(JEN_TASK_RUNTIME_BIN="$mock_runtime" "$wrapper" activity-log --since 2026-04-24T00:00:00Z --until 2026-04-25T00:00:00Z --limit 50)
assert_jq "$activity_log" '.argv == ["read-activity-log","--since","2026-04-24T00:00:00Z","--until","2026-04-25T00:00:00Z","--limit","50"]' 'activity-log delegates with window and limit'

recent_diff=$(JEN_TASK_RUNTIME_BIN="$mock_runtime" "$wrapper" recent-diff --since 2026-04-24T00:00:00Z --until 2026-04-25T00:00:00Z --limit 50 --ttl-hours 24)
assert_jq "$recent_diff" '.argv == ["read-recent-diff","--since","2026-04-24T00:00:00Z","--until","2026-04-25T00:00:00Z","--limit","50","--ttl-hours","24"]' 'recent-diff delegates with window limit and ttl'

ensure_baseline=$(JEN_TASK_RUNTIME_BIN="$mock_runtime" "$wrapper" ensure-observation-baseline --limit 50 --ttl-hours 24 --force)
assert_jq "$ensure_baseline" '.argv == ["ensure-observation-baseline","--limit","50","--ttl-hours","24","--force"]' 'ensure-observation-baseline delegates with limit ttl and force'

degraded=$(JEN_TASK_RUNTIME_BIN="$mock_runtime" "$wrapper" degraded-state)
assert_jq "$degraded" '.argv == ["explain-degraded-state"]' 'degraded-state delegates'

set +e
bad_due=$(JEN_TASK_RUNTIME_BIN="$mock_runtime" "$wrapper" due-window --from 2026-04-24 2>/dev/null)
bad_due_status=$?
set -e
assert_status "$bad_due_status" "1" 'bad due-window exits non-zero'
assert_jq "$bad_due" '.contract_version == "jen-task-runtime.v1" and .command == "read-due-window" and .status == "failed" and .failure_class == "invalid_argument"' 'bad due-window JSON failure'

set +e
bad_recent=$(JEN_TASK_RUNTIME_BIN="$mock_runtime" "$wrapper" recent-completed --since 2>/dev/null)
bad_recent_status=$?
set -e
assert_status "$bad_recent_status" "1" 'bad recent-completed exits non-zero'
assert_jq "$bad_recent" '.contract_version == "jen-task-runtime.v1" and .command == "read-recent-completed" and .status == "failed" and .failure_class == "invalid_argument"' 'bad recent-completed JSON failure'

set +e
missing_activity_since=$(JEN_TASK_RUNTIME_BIN="$mock_runtime" "$wrapper" recent-activity 2>/dev/null)
missing_activity_since_status=$?
set -e
assert_status "$missing_activity_since_status" "1" 'missing recent-activity since exits non-zero'
assert_jq "$missing_activity_since" '.contract_version == "jen-task-runtime.v1" and .command == "read-recent-activity" and .status == "failed" and .failure_class == "invalid_argument"' 'missing recent-activity since JSON failure'

set +e
bad_activity=$(JEN_TASK_RUNTIME_BIN="$mock_runtime" "$wrapper" recent-activity --since 2>/dev/null)
bad_activity_status=$?
set -e
assert_status "$bad_activity_status" "1" 'bad recent-activity exits non-zero'
assert_jq "$bad_activity" '.contract_version == "jen-task-runtime.v1" and .command == "read-recent-activity" and .status == "failed" and .failure_class == "invalid_argument"' 'bad recent-activity JSON failure'

set +e
missing_activity_log_since=$(JEN_TASK_RUNTIME_BIN="$mock_runtime" "$wrapper" activity-log 2>/dev/null)
missing_activity_log_since_status=$?
set -e
assert_status "$missing_activity_log_since_status" "1" 'missing activity-log since exits non-zero'
assert_jq "$missing_activity_log_since" '.contract_version == "jen-task-runtime.v1" and .command == "read-activity-log" and .status == "failed" and .failure_class == "invalid_argument"' 'missing activity-log since JSON failure'

set +e
bad_activity_log=$(JEN_TASK_RUNTIME_BIN="$mock_runtime" "$wrapper" activity-log --since 2>/dev/null)
bad_activity_log_status=$?
set -e
assert_status "$bad_activity_log_status" "1" 'bad activity-log exits non-zero'
assert_jq "$bad_activity_log" '.contract_version == "jen-task-runtime.v1" and .command == "read-activity-log" and .status == "failed" and .failure_class == "invalid_argument"' 'bad activity-log JSON failure'

set +e
missing_recent_diff_since=$(JEN_TASK_RUNTIME_BIN="$mock_runtime" "$wrapper" recent-diff 2>/dev/null)
missing_recent_diff_since_status=$?
set -e
assert_status "$missing_recent_diff_since_status" "1" 'missing recent-diff since exits non-zero'
assert_jq "$missing_recent_diff_since" '.contract_version == "jen-task-runtime.v1" and .command == "read-recent-diff" and .status == "failed" and .failure_class == "invalid_argument"' 'missing recent-diff since JSON failure'

set +e
bad_recent_diff=$(JEN_TASK_RUNTIME_BIN="$mock_runtime" "$wrapper" recent-diff --since 2>/dev/null)
bad_recent_diff_status=$?
set -e
assert_status "$bad_recent_diff_status" "1" 'bad recent-diff exits non-zero'
assert_jq "$bad_recent_diff" '.contract_version == "jen-task-runtime.v1" and .command == "read-recent-diff" and .status == "failed" and .failure_class == "invalid_argument"' 'bad recent-diff JSON failure'

set +e
bad_ensure=$(JEN_TASK_RUNTIME_BIN="$mock_runtime" "$wrapper" ensure-observation-baseline --limit 2>/dev/null)
bad_ensure_status=$?
set -e
assert_status "$bad_ensure_status" "1" 'bad ensure-observation-baseline exits non-zero'
assert_jq "$bad_ensure" '.contract_version == "jen-task-runtime.v1" and .command == "ensure-observation-baseline" and .status == "failed" and .failure_class == "invalid_argument"' 'bad ensure-observation-baseline JSON failure'

set +e
bad_active=$(JEN_TASK_RUNTIME_BIN="$mock_runtime" "$wrapper" active --extra 2>/dev/null)
bad_active_status=$?
set -e
assert_status "$bad_active_status" "1" 'bad active exits non-zero'
assert_jq "$bad_active" '.contract_version == "jen-task-runtime.v1" and .command == "read-active" and .status == "failed" and .failure_class == "invalid_argument"' 'bad active JSON failure'

if rg -n 'tools/todoist/todoist-api\.sh|curl|gog ' "$wrapper" >/tmp/jen-task-read-rg.out; then
  echo 'assertion failed: jen-task-read should not reference provider adapters directly' >&2
  cat /tmp/jen-task-read-rg.out >&2
  rm -f /tmp/jen-task-read-rg.out
  exit 1
fi
rm -f /tmp/jen-task-read-rg.out

echo 'ok - jen-task-read wrapper behavior'
