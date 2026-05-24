#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
runtime="$repo_root/bin/jen-task-runtime"
reconcile="$repo_root/bin/jen-todoist-deadline-reconcile"
state_file=$(mktemp)
mock_dir=$(mktemp -d)
mock_script="$mock_dir/todoist-api.sh"
idem_dir=$(mktemp -d)
rules_file="$mock_dir/rules.json"
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
printf '%s %s\n' "$cmd" "$*" >> "${JEN_DEADLINE_TEST_LOG:-/dev/null}"
case "$cmd" in
  active-snapshot)
    jq -nc '{results:[
      {id:"condo",content:"Pagar condomínio",description:null,project_id:"p",section_id:null,parent_id:null,labels:["critical"],due:{date:"2026-06-05",string:"todo mês dia 5",is_recurring:true},deadline:{date:"2026-05-10"},priority:4,updated_at:"2026-05-08T18:00:00Z"},
      {id:"manual",content:"Obrigação com prazo manual",due:{date:"2026-06-12",string:"todo mês dia 12",is_recurring:true},deadline:null,updated_at:"2026-05-08T18:00:00Z"},
      {id:"nonrec",content:"Obrigação sem recorrência",due:{date:"2026-06-07",is_recurring:false},deadline:null,updated_at:"2026-05-08T18:00:00Z"},
      {id:"before",content:"Prazo antes da execução",due:{date:"2026-06-20",string:"todo mês dia 20",is_recurring:true},deadline:null,updated_at:"2026-05-08T18:00:00Z"}
    ],next_cursor:null,complete:true}'
    ;;
  task)
    task_id="$1"
    case "$task_id" in
      condo)
        jq -nc '{id:"condo",content:"Pagar condomínio",due:{date:"2026-06-05",string:"todo mês dia 5",is_recurring:true},deadline:{date:"2026-05-10"},updated_at:"2026-05-08T18:00:00Z"}'
        ;;
      no-deadline)
        jq -nc '{id:"no-deadline",content:"Sem deadline",due:{date:"2026-06-05"},deadline:{date:"2026-06-10"},updated_at:"2026-05-08T18:00:00Z"}'
        ;;
      *)
        jq -nc --arg id "$task_id" '{id:$id,content:"Generic",due:null,deadline:null}'
        ;;
    esac
    ;;
  update-deadline-date)
    task_id="$1"
    deadline_date="$2"
    jq -nc --arg id "$task_id" --arg deadline_date "$deadline_date" '{id:$id,content:"Pagar condomínio",due:{date:"2026-06-05",string:"todo mês dia 5",is_recurring:true},deadline:{date:$deadline_date},updated_at:"2026-05-08T18:01:00Z"}'
    ;;
  clear-deadline)
    task_id="$1"
    jq -nc --arg id "$task_id" '{id:$id,content:"Sem deadline",due:{date:"2026-06-05"},deadline:null,updated_at:"2026-05-08T18:01:00Z"}'
    ;;
  *)
    jq -nc --arg cmd "$cmd" '{error:"unexpected",cmd:$cmd}' >&2
    exit 9
    ;;
esac
EOF
chmod +x "$mock_script"

read_json=$(JEN_DEADLINE_TEST_LOG="$call_log" JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" TODOIST_API_TOKEN=dummy "$runtime" read-active)
assert_jq "$read_json" '.status == "ok" and (.tasks[] | select(.id == "condo" and .deadline.date == "2026-05-10" and .due.date == "2026-06-05"))' 'read-active preserves deadline and current due cycle'

update_json=$(JEN_IDEMPOTENCY_DIR="$idem_dir/update" JEN_DEADLINE_TEST_LOG="$call_log" JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" TODOIST_API_TOKEN=dummy "$runtime" update-deadline --task-id condo --deadline 2026-06-10)
assert_jq "$update_json" '.command == "update-deadline" and .status == "ok" and .verified == true and .deadline_date == "2026-06-10" and .task.deadline.date == "2026-06-10"' 'runtime update-deadline verified output'
assert_jq "$update_json" '.mutation.gateway_plan.mutation_payload.deadline_date == "2026-06-10" and .mutation.gateway_plan.preview.fields_changed == ["deadline_date"]' 'deadline update passes through mutation gateway'

set +e
invalid_json=$(JEN_IDEMPOTENCY_DIR="$idem_dir/invalid" JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" TODOIST_API_TOKEN=dummy "$runtime" update-deadline --task-id condo --deadline tomorrow)
invalid_status=$?
set -e
assert_eq "$invalid_status" "1" 'invalid deadline should fail closed'
assert_jq "$invalid_json" '.command == "update-deadline" and .status == "failed" and .failure_class == "invalid_argument"' 'invalid deadline failure shape'

clear_json=$(JEN_IDEMPOTENCY_DIR="$idem_dir/clear" JEN_DEADLINE_TEST_LOG="$call_log" JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" TODOIST_API_TOKEN=dummy "$runtime" clear-deadline --task-id no-deadline)
assert_jq "$clear_json" '.command == "clear-deadline" and .status == "ok" and .verified == true and .task.deadline == null' 'runtime clear-deadline verified output'

cat > "$rules_file" <<'EOF'
{
  "contract_version": "jen-todoist-deadline-rules.v1",
  "rules": [
    {"task_id":"condo","name":"Condomínio","kind":"recurring_hard_obligation","deadline_rule":{"type":"due_month_day","day":10}},
    {"task_id":"manual","name":"Manual","kind":"recurring_hard_obligation","deadline_rule":{"type":"manual"}},
    {"task_id":"nonrec","name":"Nonrec","kind":"recurring_hard_obligation","deadline_rule":{"type":"due_offset_days","days":3}},
    {"task_id":"before","name":"Before","kind":"recurring_hard_obligation","deadline_rule":{"type":"due_month_day","day":10}}
  ]
}
EOF

dry_run=$(JEN_IDEMPOTENCY_DIR="$idem_dir/reconcile-dry" JEN_DEADLINE_TEST_LOG="$call_log" JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" TODOIST_API_TOKEN=dummy "$reconcile" --runtime "$runtime" --rules "$rules_file")
assert_jq "$dry_run" '.contract_version == "jen-todoist-deadline-reconcile.v1" and .status == "ok" and .mode == "dry-run" and .summary.status_counts.would_update == 1 and .summary.status_counts.needs_question == 3' 'dry-run summary shape'
assert_jq "$dry_run" '.results[] | select(.task_id == "condo" and .status == "would_update" and .due.date == "2026-06-05" and .current_deadline == "2026-05-10" and .expected_deadline == "2026-06-10")' 'deadline is computed from current due date, not stale deadline'
assert_jq "$dry_run" '.results[] | select(.task_id == "manual" and .status == "needs_question" and .reason == "manual_deadline_rule")' 'manual rule asks instead of inventing deadline'
assert_jq "$dry_run" '.results[] | select(.task_id == "nonrec" and .status == "needs_question" and .reason == "due_not_recurring_for_recurring_hard_obligation")' 'recurring hard obligation requires recurring due'
assert_jq "$dry_run" '.results[] | select(.task_id == "before" and .status == "needs_question" and .reason == "deadline_before_due_date")' 'deadline before due fails closed by default'

apply_json=$(JEN_IDEMPOTENCY_DIR="$idem_dir/reconcile-apply" JEN_DEADLINE_TEST_LOG="$call_log" JEN_TASK_RUNTIME_STATE_FILE="$state_file" JEN_TASK_RUNTIME_TODOIST_SCRIPT="$mock_script" TODOIST_API_TOKEN=dummy "$reconcile" --runtime "$runtime" --rules "$rules_file" --apply)
assert_jq "$apply_json" '.mode == "apply" and .summary.updates_attempted == 1 and .summary.updates_succeeded == 1 and (.results[] | select(.task_id == "condo" and .status == "updated" and .expected_deadline == "2026-06-10" and .update.command == "update-deadline"))' 'apply updates through runtime update-deadline'

echo "jen-task-runtime-deadline-contract: ok"
