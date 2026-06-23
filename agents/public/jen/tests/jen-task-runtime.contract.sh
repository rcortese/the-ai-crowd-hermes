#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
runtime="$repo_root/bin/jen-task-runtime"
capture="$repo_root/bin/jen-todoist-capture"
state_file=$(mktemp)
mock_dir=$(mktemp -d)
mock_script="$mock_dir/todoist-api.sh"
idem_dir=$(mktemp -d)

cleanup() {
  rm -f "$state_file"
  rm -rf "$mock_dir"
  rm -rf "$idem_dir"
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

write_mock() {
  cat > "$mock_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mode="${JEN_TASK_RUNTIME_TEST_MODE:-success}"
cmd="${1:-}"
shift || true
now="2026-04-24T16:03:00Z"
case "$mode:$cmd" in
  success:tasks|success:active-snapshot)
    jq -nc '{results:[{id:"t1",content:"Do thing",description:null,project_id:"p1",section_id:null,parent_id:null,due:{date:"2026-04-25"},priority:2,updated_at:"2026-04-24T16:03:00Z"},{id:"t2",content:"Missing optional fields",labels:null}],next_cursor:null,complete:true}'
    ;;
  success_array:active-snapshot)
    jq -nc '{results:[{id:"t-array",content:"Array shape",labels:["x"]}],next_cursor:null,complete:true}'
    ;;
  bad_shape:active-snapshot)
    jq -nc '{items:[{id:"not-supported"}],next_cursor:null,complete:true}'
    ;;
  incomplete_active_snapshot:active-snapshot)
    jq -nc '{results:[{id:"partial",content:"Partial"}],next_cursor:"more",complete:false}'
    ;;
  invalid_json:active-snapshot)
    printf 'not json\n'
    ;;
  bad_completed_shape:completed-by-completion-date)
    jq -nc '{results:[{id:"wrong-wrapper"}]}'
    ;;
  incomplete_completed_window:completed-by-completion-date)
    jq -nc '{items:[{id:"done-partial",content:"Partial"}],next_cursor:"more",complete:false}'
    ;;
  incomplete_due_window:due-window)
    jq -nc '{results:[{id:"due-partial",content:"Partial",due:{date:"2026-04-25"}}],next_cursor:"more",complete:false}'
    ;;
  duplicate_due:active-snapshot)
    jq -nc '{results:[{id:"active-1",content:"Comprar ração Brutus",due:null}],next_cursor:null,complete:true}'
    ;;
  duplicate_due:due-window)
    jq -nc '{results:[{id:"due-banho",content:"Dar banho no Brutus",due:{date:"2026-04-24",is_recurring:false}}],next_cursor:null,complete:true}'
    ;;
  partial_compound:active-snapshot)
    jq -nc '{results:[{id:"active-cortar",content:"Cortar unha do Brutus",due:{date:"2026-05-03",is_recurring:true}}],next_cursor:null,complete:true}'
    ;;
  personal_nails_not_brutus:active-snapshot)
    jq -nc '{results:[{id:"active-cortar",content:"Cortar unha",due:{date:"2026-05-03",is_recurring:true}}],next_cursor:null,complete:true}'
    ;;
  personal_nails_not_brutus:due-window)
    jq -nc '{results:[],next_cursor:null,complete:true}'
    ;;
  livro_miguel_stopword_due_diff:active-snapshot)
    jq -nc '{results:[{id:"livro-old",content:"Livro do Miguel",due:null,labels:["HomeLab"]}],next_cursor:null,complete:true}'
    ;;
  livro_miguel_stopword_due_diff:due-window)
    jq -nc '{results:[],next_cursor:null,complete:true}'
    ;;
  partial_compound:due-window)
    jq -nc '{results:[{id:"due-banho",content:"Dar banho no Brutus",due:{date:"2026-04-24",is_recurring:false}}],next_cursor:null,complete:true}'
    ;;
  recurring_overlap:active-snapshot)
    jq -nc '{results:[{id:"active-cortar",content:"Cortar unha do Brutus",due:{date:"2026-05-03",is_recurring:true}}],next_cursor:null,complete:true}'
    ;;
  recurring_overlap:due-window)
    jq -nc '{results:[],next_cursor:null,complete:true}'
    ;;
  duplicate_read_fail:active-snapshot)
    printf '{"error":"missing_token"}\n' >&2
    exit 2
    ;;
  unresolved_due:active-snapshot)
    jq -nc '{results:[],next_cursor:null,complete:true}'
    ;;
  fail_add:active-snapshot)
    jq -nc '{results:[],next_cursor:null,complete:true}'
    ;;
  fail_add:add-task)
    printf 'add-task %s\n' "$1" >> "${JEN_TASK_RUNTIME_TEST_LOG:-/dev/null}"
    printf '{"error":"network_failure"}\n' >&2
    exit 3
    ;;
  fail_tasks:active-snapshot)
    printf '{"error":"missing_token"}\n' >&2
    exit 2
    ;;
  retry_partial_transient:task|retry_partial_nontransient:task)
    jq -nc --arg id "$1" '{id:$id,content:"Retry partial",description:null,project_id:"p1",section_id:null,parent_id:null,labels:["ctx"],due:{date:"2026-05-08",string:"today",is_recurring:false},deadline:null,priority:2,updated_at:"2026-04-24T16:03:00Z"}'
    ;;
  success:add-task|personal_nails_not_brutus:add-task)
    printf 'add-task %s\n' "$1" >> "${JEN_TASK_RUNTIME_TEST_LOG:-/dev/null}"
    jq -nc --arg id 'task-1' --arg content "$1" '{id:$id,content:$content}'
    ;;
  success:update-due|personal_nails_not_brutus:update-due)
    printf 'update-due %s %s\n' "$1" "$2" >> "${JEN_TASK_RUNTIME_TEST_LOG:-/dev/null}"
    jq -nc --arg id "$1" --arg due "$2" '{id:$id,due:{string:$due}}'
    ;;
  retry_partial_transient:update-due)
    printf 'update-due %s %s\n' "$1" "$2" >> "${JEN_TASK_RUNTIME_TEST_LOG:-/dev/null}"
    if [[ ! -f "${JEN_TASK_RUNTIME_TEST_MARKER:-}" ]]; then
      : > "${JEN_TASK_RUNTIME_TEST_MARKER:-/dev/null}"
      printf '{"error":"network_failure"}\n' >&2
      exit 3
    fi
    jq -nc --arg id "$1" --arg due "$2" '{id:$id,due:{string:$due}}'
    ;;
  retry_partial_nontransient:update-due)
    printf 'update-due %s %s\n' "$1" "$2" >> "${JEN_TASK_RUNTIME_TEST_LOG:-/dev/null}"
    if [[ ! -f "${JEN_TASK_RUNTIME_TEST_MARKER:-}" ]]; then
      : > "${JEN_TASK_RUNTIME_TEST_MARKER:-/dev/null}"
      printf '{"error":"verification_failed"}\n' >&2
      exit 3
    fi
    jq -nc --arg id "$1" --arg due "$2" '{id:$id,due:{string:$due}}'
    ;;
  success:task)
    if [[ "$1" == "rec-1" ]]; then
      jq -nc --arg id "$1" '{id:$id,content:"Recurring task",description:"old",project_id:"p1",section_id:null,parent_id:null,labels:["old"],due:{date:"2026-05-12",string:"todo 7 dias",is_recurring:true},deadline:null,priority:1,updated_at:"2026-04-24T16:03:00Z"}'
    else
      jq -nc --arg id "$1" '{id:$id,content:"Metadata task",description:"old",project_id:"p1",section_id:null,parent_id:null,labels:["old"],due:null,deadline:null,priority:1,updated_at:"2026-04-24T16:03:00Z"}'
    fi
    ;;
  success:update-labels)
    printf 'update-labels %s %s\n' "$1" "${2-}" >> "${JEN_TASK_RUNTIME_TEST_LOG:-/dev/null}"
    labels_json="$(jq -nc --arg labels_csv "${2-}" '$labels_csv | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length>0))')"
    jq -nc --arg id "$1" --argjson labels "$labels_json" '{id:$id,content:"Metadata task",description:"old",project_id:"p1",labels:$labels,updated_at:"2026-04-24T16:04:00Z"}'
    ;;
  success:update-description)
    printf 'update-description %s %s\n' "$1" "${2-}" >> "${JEN_TASK_RUNTIME_TEST_LOG:-/dev/null}"
    jq -nc --arg id "$1" --arg description "${2-}" '{id:$id,content:"Metadata task",description:$description,project_id:"p1",labels:["old"],updated_at:"2026-04-24T16:04:00Z"}'
    ;;
  fail_due:add-task)
    printf 'add-task %s\n' "$1" >> "${JEN_TASK_RUNTIME_TEST_LOG:-/dev/null}"
    jq -nc --arg id 'task-partial' --arg content "$1" '{id:$id,content:$content}'
    ;;
  fail_due:active-snapshot)
    jq -nc '{results:[],next_cursor:null,complete:true}'
    ;;
  fail_due:due-window)
    jq -nc '{results:[],next_cursor:null,complete:true}'
    ;;
  fail_due:update-due)
    printf 'update-due %s %s\n' "$1" "$2" >> "${JEN_TASK_RUNTIME_TEST_LOG:-/dev/null}"
    printf '{"error":"network_failure"}\n' >&2
    exit 3
    ;;
  success:completed-info)
    jq -nc --arg ts "$now" '{captured_at:$ts,completed_info:[{project_id:"p1",completed_items:4},{section_id:"s1",completed_items:2}]}'
    ;;
  success:completed-by-completion-date)
    jq -nc '{items:[{id:"done-1",content:"Finished thing",description:"",project_id:"p1",section_id:null,parent_id:null,labels:["x"],due:null,priority:1,added_at:"2026-04-24T15:00:00Z",completed_at:"2026-04-24T16:00:00Z",updated_at:"2026-04-24T16:00:01Z"}],next_cursor:null,complete:true}'
    ;;
  success:due-window)
    jq -nc '{results:[{id:"due-1",content:"Due soon",description:null,project_id:"p1",section_id:null,parent_id:null,labels:["ctx"],due:{date:"2026-04-25",is_recurring:false},priority:4,updated_at:"2026-04-24T16:03:00Z"}],next_cursor:null,complete:true}'
    ;;
  fail_completed:completed-info)
    printf '{"error":"network_failure"}\n' >&2
    exit 3
    ;;
  fail_completed:completed-by-completion-date)
    printf '{"error":"network_failure"}\n' >&2
    exit 3
    ;;
  *)
    printf '{"error":"unexpected","mode":"%s","cmd":"%s"}\n' "$mode" "$cmd" >&2
    exit 9
    ;;
 esac
EOF
  chmod +x "$mock_script"
}

write_mock

health_json=$(JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" TODOIST_API_TOKEN=dummy "$runtime" health)
assert_jq "$health_json" '.contract_version == "jen-task-runtime.v1"' 'health contract version'
assert_jq "$health_json" '.command == "health" and .status == "ok" and .posture == "available"' 'health status/posture'
assert_jq "$health_json" '.authority == "workspace-todoist-adapter" and .token_status == "set"' 'health enums'
assert_jq "$health_json" '.checked_at == "2026-04-24T16:03:00Z" or (.checked_at | test("Z$"))' 'health checked_at RFC3339 UTC-ish'

active_json=$(JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" TODOIST_API_TOKEN=dummy "$runtime" read-active)
assert_jq "$active_json" '.status == "ok" and .source == "live" and (.tasks | type) == "array" and (.tasks | length) == 2' 'read-active live normalized array'
assert_jq "$active_json" 'if (.tasks | type) == "object" then (.tasks | has("results") | not) else true end' 'read-active does not expose provider results wrapper'
assert_jq "$active_json" '.tasks[0] == {id:"t1",content:"Do thing",description:null,project_id:"p1",section_id:null,parent_id:null,labels:[],due:{date:"2026-04-25"},deadline:null,priority:2,updated_at:"2026-04-24T16:03:00Z",source:"live"}' 'read-active normalized task shape with due/deadline passthrough'
assert_jq "$active_json" '.tasks[1].labels == [] and .tasks[1].description == null and .tasks[1].project_id == null and .tasks[1].section_id == null and .tasks[1].parent_id == null and .tasks[1].due == null and .tasks[1].deadline == null and .tasks[1].priority == null and .tasks[1].updated_at == null and .tasks[1].source == "live"' 'read-active nullable/default fields are stable'

active_array_json=$(JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" JEN_TASK_RUNTIME_TEST_MODE=success_array TODOIST_API_TOKEN=dummy "$runtime" read-active)
assert_jq "$active_array_json" '.status == "ok" and (.tasks | type) == "array" and .tasks[0].id == "t-array" and .tasks[0].labels == ["x"] and .tasks[0].source == "live"' 'read-active accepts direct array provider shape'

set +e
active_bad_shape_stdout=$(mktemp)
active_bad_shape_stderr=$(mktemp)
JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" JEN_TASK_RUNTIME_TEST_MODE=bad_shape TODOIST_API_TOKEN=dummy "$runtime" read-active >"$active_bad_shape_stdout" 2>"$active_bad_shape_stderr"
active_bad_shape_status=$?
set -e
active_bad_shape_json=$(cat "$active_bad_shape_stdout")
assert_eq "$active_bad_shape_status" "0" 'read-active bad shape fallback should exit 0'
assert_eq "$(cat "$active_bad_shape_stderr")" "" 'read-active bad shape should not leak jq stderr'
assert_jq "$active_bad_shape_json" '.status == "degraded" and .source == "degraded-metadata" and .provenance == "runtime-metadata"' 'read-active bad shape degraded fallback shape'
assert_jq "$active_bad_shape_json" 'has("tasks") | not' 'read-active bad shape degraded has no tasks'
rm -f "$active_bad_shape_stdout" "$active_bad_shape_stderr"

set +e
active_invalid_stdout=$(mktemp)
active_invalid_stderr=$(mktemp)
JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" JEN_TASK_RUNTIME_TEST_MODE=invalid_json TODOIST_API_TOKEN=dummy "$runtime" read-active >"$active_invalid_stdout" 2>"$active_invalid_stderr"
active_invalid_status=$?
set -e
active_invalid_json=$(cat "$active_invalid_stdout")
assert_eq "$active_invalid_status" "0" 'read-active invalid JSON fallback should exit 0'
assert_eq "$(cat "$active_invalid_stderr")" "" 'read-active invalid JSON should not leak jq stderr'
assert_jq "$active_invalid_json" '.status == "degraded" and .source == "degraded-metadata" and .provenance == "runtime-metadata"' 'read-active invalid JSON degraded fallback shape'
assert_jq "$active_invalid_json" 'has("tasks") | not' 'read-active invalid JSON degraded has no tasks'
rm -f "$active_invalid_stdout" "$active_invalid_stderr"

set +e
active_failed_json=$(JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" JEN_TASK_RUNTIME_TEST_MODE=fail_tasks TODOIST_API_TOKEN=dummy "$runtime" read-active)
active_failed_status=$?
set -e
assert_eq "$active_failed_status" "0" 'read-active degraded fallback should exit 0'
assert_jq "$active_failed_json" '.status == "degraded" and .source == "degraded-metadata" and .provenance == "runtime-metadata"' 'read-active degraded fallback shape'
assert_jq "$active_failed_json" 'has("tasks") | not' 'read-active degraded has no tasks'

active_incomplete_json=$(JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" JEN_TASK_RUNTIME_TEST_MODE=incomplete_active_snapshot TODOIST_API_TOKEN=dummy "$runtime" read-active)
assert_jq "$active_incomplete_json" '.status == "degraded" and .failure_class? == null and .source == "degraded-metadata"' 'read-active incomplete active snapshot degrades without task bodies'
assert_jq "$active_incomplete_json" 'has("tasks") | not' 'read-active incomplete active snapshot has no tasks'

metadata_log="$mock_dir/metadata.log"
metadata_labels=$(JEN_IDEMPOTENCY_DIR="$idem_dir/metadata-labels" JEN_TASK_RUNTIME_TEST_LOG="$metadata_log" JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" TODOIST_API_TOKEN=dummy "$runtime" update-labels --task-id meta-1 --labels ' errands, home,errands ')
assert_jq "$metadata_labels" '.command == "update-labels" and .status == "ok" and .verified == true and .task.labels == ["errands","home"]' 'update-labels normalizes duplicate labels and verifies adapter result'
assert_jq "$metadata_labels" '.mutation.gateway_plan.mutation_payload.labels == ["errands","home"] and .mutation.gateway_plan.preview.fields_changed == ["labels"]' 'update-labels mutation payload is normalized'
assert_eq "$(grep -c '^update-labels meta-1 errands,home$' "$metadata_log")" "1" 'update-labels adapter receives normalized csv'

metadata_description=$(JEN_IDEMPOTENCY_DIR="$idem_dir/metadata-description" JEN_TASK_RUNTIME_TEST_LOG="$metadata_log" JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" TODOIST_API_TOKEN=dummy "$runtime" update-description --task-id meta-2 --description 'soft cadence note')
assert_jq "$metadata_description" '.command == "update-description" and .status == "ok" and .verified == true and .task.description == "soft cadence note"' 'update-description verifies adapter result'
assert_jq "$metadata_description" '.mutation.gateway_plan.mutation_payload.description == "soft cadence note" and .mutation.gateway_plan.preview.fields_changed == ["description"]' 'update-description mutation payload is explicit'

set +e
invalid_labels=$(JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" TODOIST_API_TOKEN=dummy "$runtime" update-labels --labels home)
invalid_labels_status=$?
set -e
assert_eq "$invalid_labels_status" "1" 'update-labels without task-id fails closed'
assert_jq "$invalid_labels" '.command == "update-labels" and .status == "failed" and .failure_class == "invalid_argument"' 'update-labels invalid shape'

set +e
invalid_description=$(JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" TODOIST_API_TOKEN=dummy "$runtime" update-description --task-id meta-2)
invalid_description_status=$?
set -e
assert_eq "$invalid_description_status" "1" 'update-description without description fails closed'
assert_jq "$invalid_description" '.command == "update-description" and .status == "failed" and .failure_class == "invalid_argument"' 'update-description invalid shape'

capture_json=$(JEN_IDEMPOTENCY_DIR="$idem_dir/capture" JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" TODOIST_API_TOKEN=dummy "$capture" --content "Test task" --due tomorrow)
capture_runtime_json=$(jq -c 'if .command == "capture-task" then . else .detail.runtime end' <<<"$capture_json")
assert_jq "$capture_runtime_json" '.command == "capture-task" and .status == "ok" and .due_applied == true' 'capture wrapper delegates to runtime'
assert_jq "$capture_runtime_json" '.operation == "add-task-and-update-due" and .task.due.string == "tomorrow"' 'capture due verification'
assert_jq "$capture_runtime_json" '.mutation.gateway_plan.target_system == "todoist" and .mutation.gateway_plan.normalized_hash and .mutation.idempotency.check_status == "miss"' 'capture includes mutation gateway/idempotency metadata'

recurring_update_log="$mock_dir/recurring-update-due.log"
recurring_update=$(JEN_IDEMPOTENCY_DIR="$idem_dir/recurring-update-due" JEN_TASK_RUNTIME_TEST_LOG="$recurring_update_log" JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" TODOIST_API_TOKEN=*** "$runtime" update-due --task-id rec-1 --due 'todo 7 dias')
assert_jq "$recurring_update" '.status == "ok" and .command == "update-due" and .mutation.gateway_plan.canonical_object_type == "task" and .mutation.gateway_plan.risk_level == "medium" and .mutation.gateway_plan.requires_confirmation == false and (.mutation.gateway_plan.safety_overrides | index("safe_recurring_todoist_due_reanchor"))' 'recurring due update is recurrence-sensitive but allowed when preserving recurrence text'
assert_eq "$(grep -c '^update-due rec-1 todo 7 dias$' "$recurring_update_log")" "1" 'recurring due update reaches adapter once'

capture_duplicate=$(JEN_IDEMPOTENCY_DIR="$idem_dir/capture" JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" TODOIST_API_TOKEN=dummy "$capture" --content "Test task" --due tomorrow)
capture_duplicate_runtime=$(jq -c 'if .command == "capture-task" then . else .detail.runtime end' <<<"$capture_duplicate")
assert_jq "$capture_duplicate_runtime" '.status == "ok" and .mutation.idempotency.check_status == "miss"' 'duplicate verified replay returns stored original output without re-mutating metadata shape'

duplicate_due_log="$mock_dir/duplicate-due.log"
set +e
duplicate_due=$(JEN_TASK_RUNTIME_NOW_UTC=2026-04-24T16:03:00Z JEN_IDEMPOTENCY_DIR="$idem_dir/duplicate-due" JEN_TASK_RUNTIME_TEST_LOG="$duplicate_due_log" JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" JEN_TASK_RUNTIME_TEST_MODE=duplicate_due TODOIST_API_TOKEN=dummy "$runtime" capture-task --content "Dar banho no Brutus" --due today)
duplicate_due_status=$?
set -e
assert_eq "$duplicate_due_status" "1" 'date-bound exact duplicate exits as handled failure'
assert_jq "$duplicate_due" '.status == "failed" and .failure_class == "duplicate_existing" and .preflight.candidates[0].content == "Dar banho no Brutus" and .preflight.target_date == "2026-04-24"' 'date-bound exact duplicate preflight shape'
[[ ! -s "$duplicate_due_log" ]] || { echo 'assertion failed: duplicate due preflight called provider mutation' >&2; cat "$duplicate_due_log" >&2; exit 1; }

partial_compound_log="$mock_dir/partial-compound.log"
set +e
partial_compound=$(JEN_TASK_RUNTIME_NOW_UTC=2026-04-24T16:03:00Z JEN_IDEMPOTENCY_DIR="$idem_dir/partial-compound" JEN_TASK_RUNTIME_TEST_LOG="$partial_compound_log" JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" JEN_TASK_RUNTIME_TEST_MODE=partial_compound TODOIST_API_TOKEN=dummy "$runtime" capture-task --content "Dar banho e cortar as unhas do Brutus" --due today)
partial_compound_status=$?
set -e
assert_eq "$partial_compound_status" "1" 'partial compound overlap exits as handled failure'
assert_jq "$partial_compound" '.status == "failed" and .failure_class == "semantic_duplicate_confirmation_required" and (.preflight.candidates | map(.content) | index("Dar banho no Brutus")) != null and (.preflight.candidates | map(.content) | index("Cortar unha do Brutus")) != null' 'partial compound preflight includes due and active candidates'
[[ ! -s "$partial_compound_log" ]] || { echo 'assertion failed: partial compound preflight called provider mutation' >&2; cat "$partial_compound_log" >&2; exit 1; }

recurring_overlap_log="$mock_dir/recurring-overlap.log"
set +e
recurring_overlap=$(JEN_TASK_RUNTIME_NOW_UTC=2026-04-24T16:03:00Z JEN_IDEMPOTENCY_DIR="$idem_dir/recurring-overlap" JEN_TASK_RUNTIME_TEST_LOG="$recurring_overlap_log" JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" JEN_TASK_RUNTIME_TEST_MODE=recurring_overlap TODOIST_API_TOKEN=dummy "$runtime" capture-task --content "Cortar as unhas do Brutus" --due today)
recurring_overlap_status=$?
set -e
assert_eq "$recurring_overlap_status" "1" 'active recurring overlap exits as handled failure'
assert_jq "$recurring_overlap" '.status == "failed" and .failure_class == "duplicate_existing" and .preflight.candidates[0].content == "Cortar unha do Brutus" and .preflight.candidates[0].source_set == "active"' 'active recurring overlap is considered for date-bound capture'
[[ ! -s "$recurring_overlap_log" ]] || { echo 'assertion failed: recurring overlap preflight called provider mutation' >&2; cat "$recurring_overlap_log" >&2; exit 1; }

livro_miguel_log="$mock_dir/livro-miguel-stopword-due-diff.log"
set +e
livro_miguel=$(JEN_TASK_RUNTIME_NOW_UTC=2026-05-06T16:40:00Z JEN_IDEMPOTENCY_DIR="$idem_dir/livro-miguel-stopword-due-diff" JEN_TASK_RUNTIME_TEST_LOG="$livro_miguel_log" JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" JEN_TASK_RUNTIME_TEST_MODE=livro_miguel_stopword_due_diff TODOIST_API_TOKEN=dummy "$runtime" capture-task --content "Livro Miguel" --due today)
livro_miguel_status=$?
set -e
assert_eq "$livro_miguel_status" "1" 'Livro Miguel stopword/due-diff duplicate exits as handled failure'
assert_jq "$livro_miguel" '.status == "failed" and .failure_class == "duplicate_existing" and .preflight.target_date == "2026-05-06" and .preflight.candidates[0].content == "Livro do Miguel" and .preflight.candidates[0].due_relation == "existing_unscheduled" and (.preflight.candidates[0].match_reasons | index("canonical_tokens_equal_after_stopwords"))' 'Livro Miguel vs Livro do Miguel is blocked for edit/consolidate/confirm path'
[[ ! -s "$livro_miguel_log" ]] || { echo 'assertion failed: Livro Miguel duplicate preflight called provider mutation' >&2; cat "$livro_miguel_log" >&2; exit 1; }

personal_nails_log="$mock_dir/personal-nails-not-brutus.log"
set +e
personal_nails=$(JEN_TASK_RUNTIME_NOW_UTC=2026-04-24T16:03:00Z JEN_IDEMPOTENCY_DIR="$idem_dir/personal-nails-not-brutus" JEN_TASK_RUNTIME_TEST_LOG="$personal_nails_log" JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" JEN_TASK_RUNTIME_TEST_MODE=personal_nails_not_brutus TODOIST_API_TOKEN=dummy "$runtime" capture-task --content "Cortar as unhas do Brutus" --due today)
personal_nails_status=$?
set -e
assert_eq "$personal_nails_status" "0" 'generic personal nails task is not a Brutus duplicate'
assert_jq "$personal_nails" '.status == "ok" and .operation == "add-task-and-update-due"' 'generic personal nails task allows Brutus capture'
assert_eq "$(grep -c '^add-task Cortar as unhas do Brutus$' "$personal_nails_log")" "1" 'personal nails scenario performs one create'
assert_eq "$(grep -c '^update-due task-1 today$' "$personal_nails_log")" "1" 'personal nails scenario applies due'

duplicate_read_fail_log="$mock_dir/duplicate-read-fail.log"
set +e
duplicate_read_fail=$(JEN_IDEMPOTENCY_DIR="$idem_dir/duplicate-read-fail" JEN_TASK_RUNTIME_TEST_LOG="$duplicate_read_fail_log" JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" JEN_TASK_RUNTIME_TEST_MODE=duplicate_read_fail TODOIST_API_TOKEN=dummy "$runtime" capture-task --content "Qualquer coisa")
duplicate_read_fail_status=$?
set -e
assert_eq "$duplicate_read_fail_status" "1" 'duplicate preflight read failure exits as handled failure'
assert_jq "$duplicate_read_fail" '.status == "failed" and .failure_class == "unable_to_verify_duplicates" and .preflight.reason == "active_read_failed"' 'duplicate preflight active read failure fails closed'
[[ ! -s "$duplicate_read_fail_log" ]] || { echo 'assertion failed: duplicate read failure preflight called provider mutation' >&2; cat "$duplicate_read_fail_log" >&2; exit 1; }
set +e
duplicate_read_retry=$(JEN_IDEMPOTENCY_DIR="$idem_dir/duplicate-read-fail" JEN_TASK_RUNTIME_TEST_LOG="$duplicate_read_fail_log" JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" JEN_TASK_RUNTIME_TEST_MODE=duplicate_read_fail TODOIST_API_TOKEN=dummy "$runtime" capture-task --content "Qualquer coisa")
duplicate_read_retry_status=$?
set -e
assert_eq "$duplicate_read_retry_status" "1" 'duplicate preflight retry remains handled failure'
assert_jq "$duplicate_read_retry" '.status == "failed" and .failure_class == "unable_to_verify_duplicates" and .preflight.reason == "active_read_failed"' 'duplicate preflight failure is retryable, not unsafe replay'

unresolved_due_log="$mock_dir/unresolved-due.log"
set +e
unresolved_due=$(JEN_IDEMPOTENCY_DIR="$idem_dir/unresolved-due" JEN_TASK_RUNTIME_TEST_LOG="$unresolved_due_log" JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" JEN_TASK_RUNTIME_TEST_MODE=unresolved_due TODOIST_API_TOKEN=dummy "$runtime" capture-task --content "Preparar mochila" --due someday)
unresolved_due_status=$?
set -e
assert_eq "$unresolved_due_status" "1" 'unresolved date-bound preflight exits as handled failure'
assert_jq "$unresolved_due" '.status == "failed" and .failure_class == "unable_to_verify_duplicates" and .preflight.reason == "due_resolution_failed"' 'unresolved due string fails closed'
[[ ! -s "$unresolved_due_log" ]] || { echo 'assertion failed: unresolved due preflight called provider mutation' >&2; cat "$unresolved_due_log" >&2; exit 1; }

add_fail_log="$mock_dir/add-fail.log"
set +e
add_fail=$(JEN_IDEMPOTENCY_DIR="$idem_dir/add-fail" JEN_TASK_RUNTIME_TEST_LOG="$add_fail_log" JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" JEN_TASK_RUNTIME_TEST_MODE=fail_add TODOIST_API_TOKEN=dummy "$runtime" capture-task --content "Add failure")
add_fail_status=$?
set -e
assert_eq "$add_fail_status" "1" 'add-task failure exits as handled failure'
assert_jq "$add_fail" '.status == "failed" and .failure_class == "network_failure"' 'add-task failure emits network_failure'
add_fail_record=$("$repo_root/bin/jen-idempotency-store" --dir "$idem_dir/add-fail" get --kind intent --key "$(find "$idem_dir/add-fail" -name intents.sqlite -print -quit >/dev/null; sqlite3 "$idem_dir/add-fail/intents.sqlite" 'select key from idempotency_records limit 1;')")
assert_jq "$add_fail_record" '.record.status == "failed" and .record.result.failed_step == "add-task"' 'add-task failure records failed status'

partial_log="$mock_dir/partial.log"
set +e
partial_fail=$(JEN_IDEMPOTENCY_DIR="$idem_dir/partial" JEN_TASK_RUNTIME_TEST_LOG="$partial_log" JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" JEN_TASK_RUNTIME_TEST_MODE=fail_due TODOIST_API_TOKEN=dummy "$runtime" capture-task --content "Partial due" --due tomorrow)
partial_status=$?
set -e
assert_eq "$partial_status" "1" 'partial due failure exits as handled failure'
assert_jq "$partial_fail" '.status == "failed" and .failure_class == "network_failure"' 'partial due failure emits handled JSON failure'
assert_eq "$(grep -c '^add-task ' "$partial_log")" "1" 'partial failure calls add-task once'
set +e
partial_retry=$(JEN_IDEMPOTENCY_DIR="$idem_dir/partial" JEN_TASK_RUNTIME_TEST_LOG="$partial_log" JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" TODOIST_API_TOKEN=dummy "$runtime" capture-task --content "Partial due" --due tomorrow)
partial_retry_status=$?
set -e
assert_eq "$partial_retry_status" "0" 'partial retry completes successfully'
assert_jq "$partial_retry" '.status == "ok" and .mutation.idempotency.check_status == "duplicate" and .operation == "add-task-and-update-due"' 'partial retry uses idempotency duplicate path'
assert_eq "$(grep -c '^add-task ' "$partial_log")" "1" 'partial retry does not create second task'
assert_eq "$(grep -c '^update-due ' "$partial_log")" "2" 'partial retry retries only due update'


# Fail-closed decisions before adapter write: blocked, high/confirmation, collision, unsafe replay.
decision_helper="$mock_dir/decision-helper.sh"
cat > "$decision_helper" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${JEN_TASK_RUNTIME_HELPER_DECISION:-execute}" in
  blocked)
    jq -nc '{status:"ok",decision:"blocked",gateway_plan:{idempotency_key:"idem_blocked",normalized_hash:"nh_blocked",status:"blocked",risk_level:"blocked"},idempotency:{check_status:"miss",key:"idem_blocked",normalized_hash:"nh_blocked",record:null}}'
    ;;
  awaiting_confirmation)
    jq -nc '{status:"ok",decision:"awaiting_confirmation",gateway_plan:{idempotency_key:"idem_high",normalized_hash:"nh_high",status:"awaiting_confirmation",risk_level:"high"},idempotency:{check_status:"miss",key:"idem_high",normalized_hash:"nh_high",record:null}}'
    ;;
  collision)
    jq -nc '{status:"ok",decision:"collision",gateway_plan:{idempotency_key:"idem_collision",normalized_hash:"nh_collision",status:"planned",risk_level:"low"},idempotency:{check_status:"duplicate",key:"idem_collision",normalized_hash:"nh_collision",record:{status:"collision"}}}'
    ;;
  unsafe_replay_state)
    jq -nc '{status:"ok",decision:"unsafe_replay_state",gateway_plan:{idempotency_key:"idem_unsafe",normalized_hash:"nh_unsafe",status:"planned",risk_level:"low"},idempotency:{check_status:"duplicate",key:"idem_unsafe",normalized_hash:"nh_unsafe",record:{status:"planned"}}}'
    ;;
  *)
    echo "unexpected decision" >&2
    exit 9
    ;;
esac
EOF
chmod +x "$decision_helper"
for pair in   'blocked mutation_blocked'   'awaiting_confirmation mutation_confirmation_required'   'collision idempotency_collision'   'unsafe_replay_state unsafe_replay_state'; do
  set -- $pair
  decision="$1"
  expected_failure="$2"
  fail_closed_log="$mock_dir/fail-closed-$decision.log"
  set +e
  fail_closed_json=$(JEN_TASK_RUNTIME_MUTATION_HELPER="$decision_helper" JEN_TASK_RUNTIME_HELPER_DECISION="$decision" JEN_TASK_RUNTIME_TEST_LOG="$fail_closed_log" JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" TODOIST_API_TOKEN=dummy "$runtime" capture-task --content "Fail closed $decision")
  fail_closed_status=$?
  set -e
  assert_eq "$fail_closed_status" "1" "$decision should fail closed"
  assert_jq "$fail_closed_json" ".status == \"failed\" and .failure_class == \"$expected_failure\"" "$decision emits expected failure class"
  [[ ! -s "$fail_closed_log" ]] || { echo "assertion failed: $decision called adapter" >&2; cat "$fail_closed_log" >&2; exit 1; }
done

completed_baseline=$(JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" TODOIST_API_TOKEN=dummy "$runtime" read-recent-completed)
assert_jq "$completed_baseline" '.status == "ok" and .source == "live" and .provenance == "runtime-metadata-summary"' 'recent completed live summary shape'
assert_jq "$completed_baseline" '.summary == {baseline_present:false,delta_completed_items_total:6,observed_bucket_count:2}' 'recent completed summary schema'
assert_jq "$completed_baseline" 'has("tasks") | not' 'recent completed observational has no task bodies'

completed_second=$(JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" TODOIST_API_TOKEN=dummy "$runtime" read-recent-completed)
assert_jq "$completed_second" '.summary.baseline_present == true and .summary.delta_completed_items_total == 0' 'recent completed second pass reuses bounded baseline'

due_window=$(JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" TODOIST_API_TOKEN=dummy "$runtime" read-due-window --from 2026-04-24 --to 2026-04-27)
assert_jq "$due_window" '.status == "ok" and .source == "live" and .from == "2026-04-24" and .to == "2026-04-27" and .summary.task_count == 1' 'due-window live shape'
assert_jq "$due_window" '.complete == true' 'due-window exposes complete live window'
assert_jq "$due_window" '.tasks[0] == {id:"due-1",content:"Due soon",description:null,project_id:"p1",section_id:null,parent_id:null,labels:["ctx"],due:{date:"2026-04-25",is_recurring:false},deadline:null,priority:4,updated_at:"2026-04-24T16:03:00Z",source:"live"}' 'due-window normalized task shape'

completed_tasks=$(JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" TODOIST_API_TOKEN=dummy "$runtime" read-recent-completed --tasks --since 2026-04-24T00:00:00Z --until 2026-04-25T00:00:00Z)
assert_jq "$completed_tasks" '.status == "ok" and .source == "live" and .provenance == "live-completed-window"' 'recent completed task window live shape'
assert_jq "$completed_tasks" '.since == "2026-04-24T00:00:00Z" and .until == "2026-04-25T00:00:00Z" and .summary.completed_task_count == 1' 'recent completed task window bounds and count'
assert_jq "$completed_tasks" '.complete == true' 'recent completed task window exposes complete live window'
assert_jq "$completed_tasks" '.tasks[0] == {id:"done-1",content:"Finished thing",description:"",project_id:"p1",section_id:null,parent_id:null,labels:["x"],due:null,deadline:null,priority:1,added_at:"2026-04-24T15:00:00Z",completed_at:"2026-04-24T16:00:00Z",updated_at:"2026-04-24T16:00:01Z",source:"live"}' 'recent completed normalized task body'

for invalid_case in \
  'read-recent-completed --tasks --since' \
  'read-recent-completed --tasks --until' \
  'read-recent-completed --tasks --since --until' \
  'read-recent-completed --tasks --since banana --until 2026-04-25T00:00:00Z' \
  'read-recent-completed --tasks --since 2026-04-25T00:00:00Z --until 2026-04-24T00:00:00Z' \
  'read-due-window --from' \
  'read-due-window --to' \
  'read-due-window --from 2026-04-31 --to 2026-05-01' \
  'read-due-window --from 2026-05-02 --to 2026-05-01'; do
  set +e
  invalid_json=$(JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" TODOIST_API_TOKEN=dummy "$runtime" $invalid_case)
  invalid_status=$?
  set -e
  assert_eq "$invalid_status" "1" "$invalid_case should fail as handled invalid_argument"
  assert_jq "$invalid_json" '.status == "failed" and .failure_class == "invalid_argument"' "$invalid_case emits JSON failure"
done

set +e
completed_bad_shape=$(JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" JEN_TASK_RUNTIME_TEST_MODE=bad_completed_shape TODOIST_API_TOKEN=dummy "$runtime" read-recent-completed --tasks --since 2026-04-24T00:00:00Z --until 2026-04-25T00:00:00Z)
completed_bad_shape_status=$?
set -e
assert_eq "$completed_bad_shape_status" "1" 'recent completed task-body bad shape should fail closed'
assert_jq "$completed_bad_shape" '.status == "failed" and .failure_class == "provider_shape_invalid" and has("tasks") | not' 'recent completed task-body bad shape has no cached bodies'

set +e
completed_incomplete=$(JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" JEN_TASK_RUNTIME_TEST_MODE=incomplete_completed_window TODOIST_API_TOKEN=dummy "$runtime" read-recent-completed --tasks --since 2026-04-24T00:00:00Z --until 2026-04-25T00:00:00Z)
completed_incomplete_status=$?
set -e
assert_eq "$completed_incomplete_status" "1" 'recent completed incomplete window should fail closed'
assert_jq "$completed_incomplete" '.status == "failed" and .failure_class == "provider_shape_invalid" and has("tasks") | not' 'recent completed incomplete window does not force complete success'

set +e
due_incomplete=$(JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" JEN_TASK_RUNTIME_TEST_MODE=incomplete_due_window TODOIST_API_TOKEN=dummy "$runtime" read-due-window --from 2026-04-24 --to 2026-04-27)
due_incomplete_status=$?
set -e
assert_eq "$due_incomplete_status" "1" 'due-window incomplete window should fail closed'
assert_jq "$due_incomplete" '.status == "failed" and .failure_class == "provider_shape_invalid" and has("tasks") | not' 'due-window incomplete window does not force complete success'

set +e
completed_tasks_failed=$(JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" JEN_TASK_RUNTIME_TEST_MODE=fail_completed TODOIST_API_TOKEN=dummy "$runtime" read-recent-completed --tasks --since 2026-04-24T00:00:00Z --until 2026-04-25T00:00:00Z)
completed_tasks_failed_status=$?
set -e
assert_eq "$completed_tasks_failed_status" "1" 'recent completed task-body window should fail closed when live read fails'
assert_jq "$completed_tasks_failed" '.status == "failed" and .failure_class == "network_failure" and has("tasks") | not' 'recent completed task-body failure has no cached bodies'

set +e
completed_fallback=$(JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" JEN_TASK_RUNTIME_TEST_MODE=fail_completed TODOIST_API_TOKEN=dummy "$runtime" read-recent-completed)
completed_fallback_status=$?
set -e
assert_eq "$completed_fallback_status" "0" 'recent completed fallback should exit 0 when summary exists'
assert_jq "$completed_fallback" '.status == "degraded" and .source == "observational" and .provenance == "runtime-metadata-summary"' 'recent completed degraded fallback'
assert_jq "$completed_fallback" '.summary | keys == ["baseline_present","delta_completed_items_total","observed_bucket_count"]' 'recent completed summary keys pinned'

explain_json=$(JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" TODOIST_API_TOKEN=dummy "$runtime" explain-degraded-state)
assert_jq "$explain_json" '.status == "ok" and .provenance == "runtime-metadata"' 'explain degraded state'
assert_jq "$explain_json" '.last_verified_at | (type == "string" or . == null)' 'last_verified_at nullable/string'

missing_state_file=$(mktemp)
rm -f "$missing_state_file"
signals_empty=$(JEN_TASK_RUNTIME_STATE_FILE="$missing_state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" JEN_TASK_RUNTIME_TEST_MODE=adapter_should_not_be_called TODOIST_API_TOKEN=dummy "$runtime" classify-interaction-signals)
assert_jq "$signals_empty" '.status == "ok" and .source == "runtime-metadata" and .complete == true' 'interaction signals missing state returns ok'
assert_jq "$signals_empty" '.signals == [] and .summary == {signal_count:0,attention_worthy_count:0,action_eligible_count:0}' 'interaction signals missing state has zero signals'
[[ ! -e "$missing_state_file" ]] || { echo 'assertion failed: classify-interaction-signals created missing state file' >&2; exit 1; }
rm -f "$missing_state_file"

signals_state=$(mktemp)
cat > "$signals_state" <<'EOF'
{
  "todoist": {
    "runtime": {
      "last_failure_class": "network_failure",
      "last_failure_at": "2026-04-24T16:05:00Z",
      "read_recent_completed": {
        "last_summary": {
          "baseline_present": true,
          "delta_completed_items_total": 3,
          "observed_bucket_count": 2
        },
        "last_observed_at": "2026-04-24T16:04:00Z"
      }
    }
  }
}
EOF
signals_before=$(sha256sum "$signals_state" | awk '{print $1}')
signals_json=$(JEN_TASK_RUNTIME_STATE_FILE="$signals_state" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" JEN_TASK_RUNTIME_TEST_MODE=adapter_should_not_be_called TODOIST_API_TOKEN=dummy "$runtime" classify-interaction-signals)
signals_after=$(sha256sum "$signals_state" | awk '{print $1}')
assert_eq "$signals_before" "$signals_after" 'classify-interaction-signals must not mutate state file'
assert_jq "$signals_json" '.status == "ok" and .source == "runtime-metadata" and .summary.signal_count == 2' 'interaction signals classify existing metadata'
assert_jq "$signals_json" '.summary.attention_worthy_count == 0 and .summary.action_eligible_count == 0' 'interaction signals no attention/action counts in current implementation'
assert_jq "$signals_json" '.signals[] | has("signal_id") and .source == "runtime-metadata" and .requires_user_interruption == false' 'interaction signals stable ids and no interruption'
assert_jq "$signals_json" '.signals[] | (.level == "aggregated" or .level == "observed")' 'interaction signals current levels'
assert_jq "$signals_json" '.signals[] | has("tasks") | not' 'interaction signals do not expose tasks key'
assert_jq "$signals_json" '[.. | objects | has("content")] | any | not' 'interaction signals do not expose task content'
assert_jq "$signals_json" '[.. | objects | has("description")] | any | not' 'interaction signals do not expose task descriptions'
assert_jq "$signals_json" '.signals[] | select(.reason == "recent_completed_delta_observed") | .signal_id == "runtime-completion-delta:2026-04-24T16:04:00Z" and .level == "aggregated" and .observed_at == "2026-04-24T16:04:00Z" and .semantic.delta_completed_items_total == 3' 'completion delta signal shape'
assert_jq "$signals_json" '.signals[] | select(.reason == "todoist_runtime_degraded") | .signal_id == "runtime-degradation:network_failure:2026-04-24T16:05:00Z" and .level == "observed" and .observed_at == "2026-04-24T16:05:00Z" and .semantic.failure_class == "network_failure"' 'runtime degradation signal shape'

wrapper_signals=$(JEN_TASK_RUNTIME_STATE_FILE="$signals_state" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" JEN_TASK_RUNTIME_TEST_MODE=adapter_should_not_be_called TODOIST_API_TOKEN=dummy "$repo_root/bin/jen-task-signals")
assert_jq "$wrapper_signals" '.command == "classify-interaction-signals" and .summary.signal_count == 2' 'interaction signals wrapper delegates to runtime'

empty_state=$(mktemp)
set +e
signals_empty_state=$(JEN_TASK_RUNTIME_STATE_FILE="$empty_state" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" JEN_TASK_RUNTIME_TEST_MODE=adapter_should_not_be_called TODOIST_API_TOKEN=dummy "$runtime" classify-interaction-signals)
signals_empty_state_status=$?
set -e
assert_eq "$signals_empty_state_status" "1" 'interaction signals empty state should fail'
assert_jq "$signals_empty_state" '.status == "failed" and .failure_class == "state_corrupt"' 'interaction signals empty state failure class'

corrupt_state=$(mktemp)
printf '{not json\n' > "$corrupt_state"
set +e
signals_corrupt=$(JEN_TASK_RUNTIME_STATE_FILE="$corrupt_state" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" TODOIST_API_TOKEN=dummy "$runtime" classify-interaction-signals)
signals_corrupt_status=$?
set -e
assert_eq "$signals_corrupt_status" "1" 'interaction signals corrupt state should fail'
assert_jq "$signals_corrupt" '.status == "failed" and .failure_class == "state_corrupt"' 'interaction signals corrupt state failure class'

invalid_state=$(mktemp)
printf '{"todoist":{"runtime":[]}}\n' > "$invalid_state"
set +e
signals_invalid=$(JEN_TASK_RUNTIME_STATE_FILE="$invalid_state" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" TODOIST_API_TOKEN=dummy "$runtime" classify-interaction-signals)
signals_invalid_status=$?
set -e
assert_eq "$signals_invalid_status" "1" 'interaction signals invalid state should fail'
assert_jq "$signals_invalid" '.status == "failed" and .failure_class == "state_invalid"' 'interaction signals invalid state failure class'
rm -f "$signals_state" "$empty_state" "$corrupt_state" "$invalid_state"

rg -n 'tools/todoist/todoist-api\.sh' "$repo_root/bin" "$repo_root/tests" \
  | grep -v 'bin/jen-task-runtime' \
  | grep -v 'tests/jen-adapter-check.todoist-no-generic-cli.sh' \
  | grep -v 'tests/todoist-api.pagination.contract.sh' \
  | grep -v 'tests/jen-todoist-interaction-loop.contract.sh' \
  >/tmp/jen-task-runtime-rg.out || true
if [[ -s /tmp/jen-task-runtime-rg.out ]]; then
  echo 'assertion failed: executable repo code other than bin/jen-task-runtime references todoist-api.sh' >&2
  cat /tmp/jen-task-runtime-rg.out >&2
  exit 1
fi
rm -f /tmp/jen-task-runtime-rg.out

rg -n 'todoist\.runtime' "$repo_root/bin" "$repo_root/tests" \
  | grep -v 'bin/jen-task-runtime' \
  | grep -v 'tests/jen-task-runtime.recent-diff.contract.sh' \
  | grep -v 'tests/jen-task-runtime.activity-log.contract.sh' \
  | grep -v 'tests/jen-task-runtime.recent-activity.contract.sh' \
  | grep -v 'tests/jen-task-runtime.ensure-baseline.contract.sh' \
  | grep -v 'tests/jen-daily-control-tower.contract.sh' \
  >/tmp/jen-task-runtime-state-rg.out || true
if [[ -s /tmp/jen-task-runtime-state-rg.out ]]; then
  echo 'assertion failed: executable repo code other than bin/jen-task-runtime references todoist.runtime' >&2
  cat /tmp/jen-task-runtime-state-rg.out >&2
  exit 1
fi
rm -f /tmp/jen-task-runtime-state-rg.out

rg -n '/home/rcortese/\.config/moss/todoist\.env' \
  "$repo_root/bin" "$repo_root/tools" "$repo_root/tests" "$repo_root/docs/references" "$repo_root/.gitignore" \
  >/tmp/jen-task-runtime-legacy-secret-path.out || true
if [[ -s /tmp/jen-task-runtime-legacy-secret-path.out ]]; then
  echo 'assertion failed: active Jen boundary still references legacy host-global Todoist secret path' >&2
  cat /tmp/jen-task-runtime-legacy-secret-path.out >&2
  exit 1
fi
rm -f /tmp/jen-task-runtime-legacy-secret-path.out

echo 'ok - jen-task-runtime contract and boundary behavior'
