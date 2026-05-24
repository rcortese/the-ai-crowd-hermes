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
    echo "assertion failed: $message (expected $expected got $actual)" >&2
    exit 1
  fi
}

cat > "$mock_adapter" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
mode="${JEN_BASELINE_MODE:-current}"
printf '%s\n' "$*" >> "$(dirname "$0")/adapter-args.log"
if [[ "${1:-}" != "active-snapshot" ]]; then
  jq -nc --arg got "${1:-}" '{error:"unexpected_command",got:$got}' >&2
  exit 4
fi
case "$mode" in
  current)
    jq -nc '{results:[
      {id:"1",content:"Task one",description:"desc",project_id:"p1",section_id:null,parent_id:null,labels:["b","a"],due:{date:"2026-04-28"},priority:2,updated_at:"2026-04-27T02:00:00Z"},
      {id:"2",content:"Task two",description:"",project_id:"p2",section_id:null,parent_id:null,labels:[],due:null,priority:1,updated_at:"2026-04-27T02:05:00Z"}
    ],next_cursor:null,complete:true,page_count:1}'
    ;;
  changed)
    jq -nc '{results:[{id:"1",content:"Task one changed",labels:[],priority:1,updated_at:"2026-04-27T04:00:00Z"}],next_cursor:null,complete:true,page_count:1}'
    ;;
  incomplete)
    jq -nc '{results:[],next_cursor:"abc",complete:false,page_count:1}'
    ;;
  fail)
    jq -nc '{error:"network_failure"}' >&2
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

# Missing baseline refreshes and writes bounded snapshot.
json=$(JEN_BASELINE_MODE=current JEN_TASK_RUNTIME_NOW_UTC=2026-04-27T03:00:00Z run_runtime ensure-observation-baseline --limit 200 --ttl-hours 48)
assert_jq "$json" '.command == "ensure-observation-baseline" and .status == "ok" and .refreshed == true and .refresh_reason == "missing" and .summary.task_count == 2' 'missing baseline refresh output'
assert_jq "$(cat "$snapshot_file")" '.contract_version == "jen-todoist-observation-snapshot.v1" and .schema_version == 1 and .limit == 200 and .ttl_hours == 48 and .truncated == false and (.tasks|length) == 2 and (.tasks[0].labels == ["a","b"])' 'snapshot schema and normalized tasks'
assert_jq "$(cat "$state_file")" '.todoist.runtime.ensure_observation_baseline.last_ensure.refreshed == true and (.todoist.runtime | tostring | contains("Task one") | not)' 'runtime metadata excludes task bodies'
assert_eq "$(wc -l < "$mock_dir/adapter-args.log" | tr -d ' ')" "1" 'adapter called once for missing baseline'

# Fresh baseline does not overwrite or call provider.
before_snapshot=$(cat "$snapshot_file")
: > "$mock_dir/adapter-args.log"
json=$(JEN_BASELINE_MODE=changed JEN_TASK_RUNTIME_NOW_UTC=2026-04-27T04:00:00Z run_runtime ensure-observation-baseline --limit 200 --ttl-hours 48)
assert_jq "$json" '.status == "ok" and .refreshed == false and .refresh_reason == "fresh" and .baseline_observed_at == "2026-04-27T03:00:00Z"' 'fresh baseline not overwritten'
assert_eq "$(cat "$snapshot_file")" "$before_snapshot" 'fresh ensure preserves snapshot'
assert_eq "$(wc -l < "$mock_dir/adapter-args.log" | tr -d ' ')" "0" 'fresh ensure does not call adapter'

# Force overwrites explicitly.
json=$(JEN_BASELINE_MODE=changed JEN_TASK_RUNTIME_NOW_UTC=2026-04-27T04:00:00Z run_runtime ensure-observation-baseline --force --limit 200 --ttl-hours 48)
assert_jq "$json" '.status == "ok" and .refreshed == true and .force == true and .refresh_reason == "forced" and .summary.task_count == 1' 'force refresh output'
assert_jq "$(cat "$snapshot_file")" '.observed_at == "2026-04-27T04:00:00Z" and .task_count == 1 and .tasks[0].content == "Task one changed"' 'force overwrites snapshot'

# Stale baseline refreshes without force.
cat > "$snapshot_file" <<'JSON'
{"contract_version":"jen-todoist-observation-snapshot.v1","schema_version":1,"observed_at":"2026-04-20T00:00:00Z","source":"live-active-observation","task_count":1,"limit":200,"ttl_hours":48,"truncated":false,"tasks":[{"id":"old","content":"Old"}]}
JSON
json=$(JEN_BASELINE_MODE=current JEN_TASK_RUNTIME_NOW_UTC=2026-04-27T04:00:00Z run_runtime ensure-observation-baseline --limit 200 --ttl-hours 48)
assert_jq "$json" '.refreshed == true and .refresh_reason == "stale"' 'stale baseline refreshes'

set +e
bad_ttl=$(run_runtime ensure-observation-baseline --ttl-hours 0)
bad_ttl_status=$?
set -e
assert_eq "$bad_ttl_status" "1" 'bad ttl exits non-zero'
assert_jq "$bad_ttl" '.status == "failed" and .failure_class == "invalid_argument"' 'bad ttl failure'

set +e
bad_provider=$(JEN_BASELINE_MODE=incomplete JEN_TASK_RUNTIME_NOW_UTC=2026-04-27T04:00:00Z run_runtime ensure-observation-baseline --force)
bad_provider_status=$?
set -e
assert_eq "$bad_provider_status" "1" 'bad provider exits non-zero'
assert_jq "$bad_provider" '.status == "failed" and .failure_class == "provider_shape_invalid"' 'bad provider failure'

echo 'ok - jen-task-runtime ensure-observation-baseline behavior'
