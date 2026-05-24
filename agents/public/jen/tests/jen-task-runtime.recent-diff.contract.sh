#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
runtime="$repo_root/bin/jen-task-runtime"
mock_dir=$(mktemp -d)
state_file="$mock_dir/heartbeat-state.json"
snapshot_file="$mock_dir/snapshot.json"
mock_adapter="$mock_dir/todoist-api.sh"
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
mode="${JEN_RECENT_DIFF_MODE:-current}"
printf '%s
' "$*" >> "$(dirname "$0")/adapter-args.log"
if [[ "${1:-}" != "active-snapshot" ]]; then
  jq -nc --arg got "${1:-}" '{error:"unexpected_command",got:$got}' >&2
  exit 4
fi
case "$mode" in
  current)
    jq -nc '{results:[
      {id:"1",content:"Task one edited",description:"new",project_id:"p1",section_id:null,parent_id:null,labels:["b","a"],due:{date:"2026-04-28"},priority:2,updated_at:"2026-04-27T02:00:00Z"},
      {id:"3",content:"Task three",description:"",project_id:"p2",section_id:null,parent_id:null,labels:[],due:null,priority:1,updated_at:"2026-04-27T02:05:00Z"}
    ],next_cursor:null,complete:true,page_count:1}'
    ;;
  same)
    jq -nc '{results:[
      {id:"1",content:"Task one",description:"old",project_id:"p1",section_id:null,parent_id:null,labels:["a"],due:null,priority:1,updated_at:"2026-04-26T20:00:00Z"},
      {id:"2",content:"Task two",description:"",project_id:"p1",section_id:null,parent_id:null,labels:[],due:null,priority:1,updated_at:"2026-04-26T20:00:00Z"}
    ],next_cursor:null,complete:true,page_count:1}'
    ;;
  incomplete)
    jq -nc '{results:[],next_cursor:"abc",complete:false,page_count:1}'
    ;;
  fail)
    exit 3
    ;;
  *) exit 9 ;;
esac
MOCK
chmod +x "$mock_adapter"

run_runtime() {
  env \
    JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_adapter" \
    JEN_TASK_RUNTIME_STATE_FILE="$state_file" \
    JEN_TODOIST_OBSERVATION_STATE_FILE="$snapshot_file" \
    JEN_TASK_RUNTIME_NOW_UTC="${JEN_TASK_RUNTIME_NOW_UTC:-}" \
    "$runtime" "$@"
}

assert_adapter_log_contains_active_snapshot() {
  local log_file="$mock_dir/adapter-args.log"
  [[ -f "$log_file" ]] || { echo 'adapter log missing' >&2; exit 1; }
  if ! grep -qx 'active-snapshot 200' "$log_file"; then
    echo 'assertion failed: recent-diff must call active-snapshot adapter boundary' >&2
    cat "$log_file" >&2
    exit 1
  fi
  : > "$log_file"
}

# no baseline -> degraded, no diff claim, writes snapshot atomically to configured untracked path
json=$(JEN_RECENT_DIFF_MODE=current JEN_TASK_RUNTIME_NOW_UTC=2026-04-27T03:00:00Z run_runtime read-recent-diff --since 2026-04-27T00:00:00Z --until 2026-04-27T03:00:00Z)
assert_jq "$json" '.command == "read-recent-diff" and .status == "degraded" and .baseline_present == false and .coverage_status == "none"' 'no baseline degraded shape'
assert_jq "$json" '.diff.changed == [] and .diff.added_to_active_observation == [] and .diff.removed_from_active_observation == []' 'no baseline emits no diffs'
assert_jq "$json" '(.limitations | index("baseline_missing_or_stale_no_diff_claim"))' 'no baseline limitation'
[[ -f "$snapshot_file" ]] || { echo 'snapshot file was not written' >&2; exit 1; }
assert_jq "$(cat "$snapshot_file")" '.contract_version == "jen-todoist-observation-snapshot.v1" and (.tasks | length == 2)' 'snapshot file shape'

# fresh baseline before since -> net observational diff with before/after and scoped removed semantics
cat > "$snapshot_file" <<'JSON'
{
  "contract_version":"jen-todoist-observation-snapshot.v1",
  "observed_at":"2026-04-26T23:00:00Z",
  "source":"live-active-observation",
  "task_count":2,
  "tasks":[
    {"id":"1","content":"Task one","description":"old","project_id":"p1","section_id":null,"parent_id":null,"labels":["a"],"due":null,"priority":1,"updated_at":"2026-04-26T20:00:00Z","unexpected_cache_field":"must-not-leak"},
    {"id":"2","content":"Task two","description":"","project_id":"p1","section_id":null,"parent_id":null,"labels":[],"due":null,"priority":1,"updated_at":"2026-04-26T20:00:00Z"}
  ]
}
JSON
json=$(JEN_RECENT_DIFF_MODE=current JEN_TASK_RUNTIME_NOW_UTC=2026-04-27T03:00:00Z run_runtime read-recent-diff --since 2026-04-27T00:00:00Z --until 2026-04-27T03:00:00Z)
assert_jq "$json" '.status == "ok" and .coverage_status == "net_observation_baseline_before_since" and .baseline_observed_at == "2026-04-26T23:00:00Z" and .current_observed_at == "2026-04-27T03:00:00Z"' 'fresh baseline before since coverage'
assert_jq "$json" '.diff.changed | length == 1' 'changed task detected'
assert_jq "$json" '(.diff.changed[0].changed_fields | index("content")) and (.diff.changed[0].changed_fields | index("labels")) and .diff.changed[0].before.content == "Task one" and .diff.changed[0].after.content == "Task one edited"' 'field-level before after diff'
assert_jq "$json" '(.diff.changed[0].before | has("unexpected_cache_field") | not)' 'baseline extra fields are not echoed in diff output'
assert_jq "$json" '(.diff.added_to_active_observation | length == 1) and .diff.added_to_active_observation[0].id == "3"' 'added active observation'
assert_jq "$json" '(.diff.removed_from_active_observation | length == 1) and .diff.removed_from_active_observation[0].id == "2"' 'removed active observation'
assert_jq "$json" '(.limitations | index("removed_from_active_observation_does_not_imply_deleted_completed_or_moved"))' 'removed semantics limitation'
assert_jq "$(cat "$state_file")" '.todoist.runtime.read_recent_diff.last_diff_window.changed_count == 1 and (.todoist.runtime | tostring | contains("Task one edited") | not)' 'runtime metadata has counts but no task bodies'

# baseline after requested since -> degraded partial coverage
cat > "$snapshot_file" <<'JSON'
{
  "contract_version":"jen-todoist-observation-snapshot.v1",
  "observed_at":"2026-04-27T02:30:00Z",
  "source":"live-active-observation",
  "task_count":1,
  "tasks":[{"id":"1","content":"Task one","description":"old","project_id":"p1","section_id":null,"parent_id":null,"labels":[],"due":null,"priority":1,"updated_at":"2026-04-27T02:30:00Z"}]
}
JSON
json=$(JEN_RECENT_DIFF_MODE=current JEN_TASK_RUNTIME_NOW_UTC=2026-04-27T03:00:00Z run_runtime read-recent-diff --since 2026-04-27T00:00:00Z --until 2026-04-27T03:00:00Z)
assert_jq "$json" '.status == "degraded" and .coverage_status == "partial_baseline_after_since" and (.limitations | index("baseline_after_requested_since_misses_early_interval"))' 'baseline after since partial'

# stale baseline -> degraded/no diffs
cat > "$snapshot_file" <<'JSON'
{
  "contract_version":"jen-todoist-observation-snapshot.v1",
  "observed_at":"2026-04-20T00:00:00Z",
  "source":"live-active-observation",
  "task_count":1,
  "tasks":[{"id":"old","content":"Old","labels":[]}]
}
JSON
json=$(JEN_RECENT_DIFF_MODE=current JEN_TASK_RUNTIME_NOW_UTC=2026-04-27T03:00:00Z run_runtime read-recent-diff --since 2026-04-27T00:00:00Z --until 2026-04-27T03:00:00Z --ttl-hours 48)
assert_jq "$json" '.status == "degraded" and .coverage_status == "none" and .baseline_fresh == false and .summary.changed_count == 0' 'stale baseline ignored'

# past until is rejected because current live observation cannot answer past-ending windows
set +e
past=$(JEN_RECENT_DIFF_MODE=current JEN_TASK_RUNTIME_NOW_UTC=2026-04-27T03:00:00Z run_runtime read-recent-diff --since 2026-04-27T00:00:00Z --until 2026-04-27T02:00:00Z)
past_status=$?
set -e
assert_eq "$past_status" "1" 'past until rejected'
assert_jq "$past" '.status == "failed" and .failure_class == "invalid_argument"' 'past until failure'

set +e
future=$(JEN_RECENT_DIFF_MODE=current JEN_TASK_RUNTIME_NOW_UTC=2026-04-27T03:00:00Z run_runtime read-recent-diff --since 2026-04-27T03:30:00Z --until 2026-04-27T03:30:00Z)
future_status=$?
set -e
assert_eq "$future_status" "1" 'future until rejected'
assert_jq "$future" '.status == "failed" and .failure_class == "invalid_argument"' 'future until failure'

set +e
missing_since=$(run_runtime read-recent-diff --until 2026-04-27T03:00:00Z)
missing_since_status=$?
set -e
assert_eq "$missing_since_status" "1" 'missing since rejected'
assert_jq "$missing_since" '.status == "failed" and .failure_class == "invalid_argument"' 'missing since failure'

set +e
bad_provider=$(JEN_RECENT_DIFF_MODE=incomplete JEN_TASK_RUNTIME_NOW_UTC=2026-04-27T03:00:00Z run_runtime read-recent-diff --since 2026-04-27T00:00:00Z --until 2026-04-27T03:00:00Z)
bad_provider_status=$?
set -e
assert_eq "$bad_provider_status" "1" 'incomplete provider fails closed'
assert_jq "$bad_provider" '.status == "failed" and .failure_class == "provider_shape_invalid"' 'incomplete provider failure shape'

echo 'ok - jen-task-runtime recent-diff behavior'
