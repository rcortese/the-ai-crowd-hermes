#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
runtime="$repo_root/bin/jen-task-runtime"
state_file=$(mktemp)
mock_dir=$(mktemp -d)
mock_script="$mock_dir/todoist-api.sh"

cleanup() {
  rm -f "$state_file"
  rm -rf "$mock_dir"
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

cat > "$mock_script" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

mode=$JEN_TASK_RUNTIME_TEST_MODE
cmd=$1
shift || true
case "$mode:$cmd" in
  retry_partial_transient:task|retry_partial_rate_limited:task|retry_partial_nontransient:task)
    jq -nc --arg id "$1" '{id:$id,content:"Retry partial",description:null,project_id:"p1",section_id:null,parent_id:null,labels:["ctx"],due:{date:"2026-05-08",string:"today",is_recurring:false},deadline:null,priority:2,updated_at:"2026-04-24T16:03:00Z"}'
    ;;
  retry_partial_transient:update-due)
    printf 'update-due %s %s
' "$1" "$2" >> "$JEN_TASK_RUNTIME_TEST_LOG"
    if [[ ! -f "$JEN_TASK_RUNTIME_TEST_MARKER" ]]; then
      : > "$JEN_TASK_RUNTIME_TEST_MARKER"
      printf '{"error":"network_failure"}
' >&2
      exit 3
    fi
    jq -nc --arg id "$1" --arg due "$2" '{id:$id,due:{string:$due}}'
    ;;
  retry_partial_rate_limited:update-due)
    printf 'update-due %s %s
' "$1" "$2" >> "$JEN_TASK_RUNTIME_TEST_LOG"
    if [[ ! -f "$JEN_TASK_RUNTIME_TEST_MARKER" ]]; then
      : > "$JEN_TASK_RUNTIME_TEST_MARKER"
      printf '{"error":"rate_limited"}
' >&2
      exit 3
    fi
    jq -nc --arg id "$1" --arg due "$2" '{id:$id,due:{string:$due}}'
    ;;
  retry_partial_nontransient:update-due)
    printf 'update-due %s %s
' "$1" "$2" >> "$JEN_TASK_RUNTIME_TEST_LOG"
    if [[ ! -f "$JEN_TASK_RUNTIME_TEST_MARKER" ]]; then
      : > "$JEN_TASK_RUNTIME_TEST_MARKER"
      printf '{"error":"verification_failed"}
' >&2
      exit 3
    fi
    jq -nc --arg id "$1" --arg due "$2" '{id:$id,due:{string:$due}}'
    ;;
  retry_partial_request_failure:task)
    jq -nc --arg id "$1" '{id:$id,content:"Retry partial",description:null,project_id:"p1",section_id:null,parent_id:null,labels:["ctx"],due:{date:"2026-05-08",string:"today",is_recurring:false},deadline:null,priority:2,updated_at:"2026-04-24T16:03:00Z"}'
    ;;
  retry_partial_request_failure:update-due)
    printf 'update-due %s %s
' "$1" "$2" >> "$JEN_TASK_RUNTIME_TEST_LOG"
    if [[ ! -f "$JEN_TASK_RUNTIME_TEST_MARKER" ]]; then
      : > "$JEN_TASK_RUNTIME_TEST_MARKER"
      printf '{"error":"not_found"}
' >&2
      exit 4
    fi
    jq -nc --arg id "$1" --arg due "$2" '{id:$id,due:{string:$due}}'
    ;;
  *)
    printf '{"error":"unexpected","mode":"%s","cmd":"%s"}
' "$mode" "$cmd" >&2
    exit 9
    ;;
esac
MOCK
chmod +x "$mock_script"

transient_log="$mock_dir/transient.log"
transient_marker="$mock_dir/transient.marker"
set +e
first_retry=$(JEN_TASK_RUNTIME_TEST_MODE=retry_partial_transient JEN_TASK_RUNTIME_TEST_LOG="$transient_log" JEN_TASK_RUNTIME_TEST_MARKER="$transient_marker" JEN_IDEMPOTENCY_DIR="$mock_dir/idem-transient" JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" TODOIST_API_TOKEN=dummy "$runtime" update-due --task-id retry-1 --due 2026-05-11)
first_retry_status=$?
set -e
assert_eq "$first_retry_status" "1" 'transient retry first attempt fails closed'
assert_jq "$first_retry" '.status == "failed" and .failure_class == "network_failure"' 'transient retry first attempt records network failure'
second_retry=$(JEN_TASK_RUNTIME_TEST_MODE=retry_partial_transient JEN_TASK_RUNTIME_TEST_LOG="$transient_log" JEN_TASK_RUNTIME_TEST_MARKER="$transient_marker" JEN_IDEMPOTENCY_DIR="$mock_dir/idem-transient" JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" TODOIST_API_TOKEN=dummy "$runtime" update-due --task-id retry-1 --due 2026-05-11)
assert_jq "$second_retry" '.status == "ok" and .verified == true and .due_string == "2026-05-11" and .task.due.string == "2026-05-11"' 'transient retry second attempt succeeds'
assert_eq "$(grep -c '^update-due retry-1 2026-05-11$' "$transient_log")" "2" 'transient retry path replays the adapter'

rate_limited_log="$mock_dir/rate-limited.log"
rate_limited_marker="$mock_dir/rate-limited.marker"
set +e
first_rate_limited=$(JEN_TASK_RUNTIME_TEST_MODE=retry_partial_rate_limited JEN_TASK_RUNTIME_TEST_LOG="$rate_limited_log" JEN_TASK_RUNTIME_TEST_MARKER="$rate_limited_marker" JEN_IDEMPOTENCY_DIR="$mock_dir/idem-rate-limited" JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" TODOIST_API_TOKEN=dummy "$runtime" update-due --task-id retry-rate --due 2026-05-11)
first_rate_limited_status=$?
set -e
assert_eq "$first_rate_limited_status" "1" 'rate-limited retry first attempt fails closed'
assert_jq "$first_rate_limited" '.status == "failed" and .failure_class == "rate_limited"' 'rate-limited retry first attempt records rate_limited'
second_rate_limited=$(JEN_TASK_RUNTIME_TEST_MODE=retry_partial_rate_limited JEN_TASK_RUNTIME_TEST_LOG="$rate_limited_log" JEN_TASK_RUNTIME_TEST_MARKER="$rate_limited_marker" JEN_IDEMPOTENCY_DIR="$mock_dir/idem-rate-limited" JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" TODOIST_API_TOKEN=dummy "$runtime" update-due --task-id retry-rate --due 2026-05-11)
assert_jq "$second_rate_limited" '.status == "ok" and .verified == true and .due_string == "2026-05-11" and .task.due.string == "2026-05-11"' 'rate-limited retry second attempt succeeds'
assert_eq "$(grep -c '^update-due retry-rate 2026-05-11$' "$rate_limited_log")" "2" 'rate-limited retry path replays the adapter'

nontransient_log="$mock_dir/nontransient.log"
nontransient_marker="$mock_dir/nontransient.marker"
set +e
first_nontransient=$(JEN_TASK_RUNTIME_TEST_MODE=retry_partial_nontransient JEN_TASK_RUNTIME_TEST_LOG="$nontransient_log" JEN_TASK_RUNTIME_TEST_MARKER="$nontransient_marker" JEN_IDEMPOTENCY_DIR="$mock_dir/idem-nontransient" JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" TODOIST_API_TOKEN=dummy "$runtime" update-due --task-id retry-2 --due 2026-05-11)
first_nontransient_status=$?
set -e
assert_eq "$first_nontransient_status" "1" 'non-transient retry first attempt fails closed'
assert_jq "$first_nontransient" '.status == "failed" and .failure_class == "verification_failed"' 'non-transient retry first attempt records verification failure'
set +e
second_nontransient=$(JEN_TASK_RUNTIME_TEST_MODE=retry_partial_nontransient JEN_TASK_RUNTIME_TEST_LOG="$nontransient_log" JEN_TASK_RUNTIME_TEST_MARKER="$nontransient_marker" JEN_IDEMPOTENCY_DIR="$mock_dir/idem-nontransient" JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" TODOIST_API_TOKEN=dummy "$runtime" update-due --task-id retry-2 --due 2026-05-11)
second_nontransient_status=$?
set -e
assert_eq "$second_nontransient_status" "1" 'non-transient replay remains blocked'
assert_jq "$second_nontransient" '.status == "failed" and .failure_class == "unsafe_replay_state"' 'non-transient replay is rejected as unsafe'
assert_eq "$(grep -c '^update-due retry-2 2026-05-11$' "$nontransient_log")" "1" 'non-transient replay does not reach adapter again'

request_failure_log="$mock_dir/request-failure.log"
request_failure_marker="$mock_dir/request-failure.marker"
set +e
first_request_failure=$(JEN_TASK_RUNTIME_TEST_MODE=retry_partial_request_failure JEN_TASK_RUNTIME_TEST_LOG="$request_failure_log" JEN_TASK_RUNTIME_TEST_MARKER="$request_failure_marker" JEN_IDEMPOTENCY_DIR="$mock_dir/idem-request-failure" JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" TODOIST_API_TOKEN=dummy "$runtime" update-due --task-id retry-3 --due 2026-05-11)
first_request_failure_status=$?
set -e
assert_eq "$first_request_failure_status" "1" 'request_failure first attempt fails closed'
assert_jq "$first_request_failure" '.status == "failed" and .failure_class == "request_failure"' 'request_failure first attempt records request failure'
set +e
second_request_failure=$(JEN_TASK_RUNTIME_TEST_MODE=retry_partial_request_failure JEN_TASK_RUNTIME_TEST_LOG="$request_failure_log" JEN_TASK_RUNTIME_TEST_MARKER="$request_failure_marker" JEN_IDEMPOTENCY_DIR="$mock_dir/idem-request-failure" JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" TODOIST_API_TOKEN=dummy "$runtime" update-due --task-id retry-3 --due 2026-05-11)
second_request_failure_status=$?
set -e
assert_eq "$second_request_failure_status" "1" 'request_failure replay remains blocked'
assert_jq "$second_request_failure" '.status == "failed" and .failure_class == "unsafe_replay_state"' 'request_failure replay is rejected as unsafe'
assert_eq "$(grep -c '^update-due retry-3 2026-05-11$' "$request_failure_log")" "1" 'request_failure replay does not reach adapter again'

echo 'jen-task-runtime-retry-partial-contract: ok'
