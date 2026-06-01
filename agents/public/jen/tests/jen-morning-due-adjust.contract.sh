#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="$ROOT/bin/jen-morning-due-adjust"

fail() { echo "assertion failed: $*" >&2; exit 1; }
assert_jq() {
  local json="$1" filter="$2" message="$3"
  if ! jq -e "$filter" <<<"$json" >/dev/null; then
    echo "assertion failed: $message" >&2
    echo "$json" >&2
    exit 1
  fi
}

[[ -x "$helper" ]] || fail "missing executable wrapper: $helper"

mock_dir=$(mktemp -d)
trap 'rm -rf "$mock_dir"' EXIT
sem_log="$mock_dir/semantics.log"
runtime_log="$mock_dir/runtime.log"
audit_dir="$mock_dir/audit"
space_dir="$mock_dir/path with spaces"
mkdir -p "$space_dir"
mock_semantics="$space_dir/jen-todoist-due-semantics mock"
mock_runtime="$space_dir/jen-task-runtime mock"

cat > "$mock_semantics" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${JEN_MORNING_TEST_SEMANTICS_LOG:?}"
[[ "$*" == "live-due-window --from 2026-05-28 --to 2026-05-28 --today 2026-05-29" ]] || { jq -nc '{status:"failed",failure_class:"unexpected_semantics_args"}'; exit 1; }
jq -nc '{contract_version:"jen-todoist-due-semantics.v1",command:"live-due-window",status:"ok",source:"live",today:"2026-05-29",from:"2026-05-28",to:"2026-05-28",summary:{task_count:5,category_counts:{soft_surface:1,hard_deadline:1,recurring_hard_obligation:1,recurring_maintenance:1,ambiguous:1}},tasks:[{id:"soft-1",content:"Review note",due:{date:"2026-05-28",is_recurring:false},deadline:null,past_due_raw:true,classification:{category:"soft_surface",confidence:"low",reason:"soft",suggested_action:"Keep it today, move it to `Esta Semana`, or remove the due date."},signals:["past_due_raw"]},{id:"hard-1",content:"Pagar boleto",due:{date:"2026-05-28",is_recurring:false},deadline:{date:"2026-05-30"},past_due_raw:true,classification:{category:"hard_deadline",confidence:"high",reason:"hard",suggested_action:"Do it."},signals:["past_due_raw","hard_deadline_cue"]},{id:"rec-hard-1",content:"Pagar aluguel",due:{date:"2026-05-28",string:"todo mês",is_recurring:true},deadline:{date:"2026-05-31"},past_due_raw:true,classification:{category:"recurring_hard_obligation",confidence:"high",reason:"rec hard",suggested_action:"Preserve recurring due."},signals:["past_due_raw","todoist_recurring_due"]},{id:"rec-maint-1",content:"Weekly review",due:{date:"2026-05-28",string:"every week",is_recurring:true},deadline:null,past_due_raw:true,classification:{category:"recurring_maintenance",confidence:"high",reason:"rec",suggested_action:"Re-anchor cadence."},signals:["past_due_raw","todoist_recurring_due"]},{id:"amb-1",content:"",due:null,deadline:null,past_due_raw:false,classification:{category:"ambiguous",confidence:"low",reason:"amb",suggested_action:"Ask."},signals:[]}],complete:true}'
EOF
chmod +x "$mock_semantics"

cat > "$mock_runtime" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${JEN_MORNING_TEST_RUNTIME_LOG:?}"
case "$*" in
  "update-due --task-id soft-1 --due 2026-05-29") jq -nc '{status:"ok",command:"update-due",task:{id:"soft-1",due:{date:"2026-05-29"}},verified:true}' ;;
  "update-due --task-id soft-1 --due no date") jq -nc '{status:"ok",command:"update-due",task:{id:"soft-1",due:null},verified:true}' ;;
  "move-task --task-id soft-1 --project-id proj-week") jq -nc '{status:"ok",command:"move-task",task:{id:"soft-1",project_id:"proj-week"},verified:true}' ;;
  *) jq -nc '{status:"failed",failure_class:"unexpected_runtime_args"}'; exit 1 ;;
esac
EOF
chmod +x "$mock_runtime"

dry_json="$(JEN_MORNING_DUE_ADJUST_SEMANTICS="$mock_semantics" JEN_MORNING_DUE_ADJUST_TASK_RUNTIME="$mock_runtime" JEN_MORNING_TEST_SEMANTICS_LOG="$sem_log" JEN_MORNING_TEST_RUNTIME_LOG="$runtime_log" JEN_MORNING_DUE_ADJUST_AUDIT_DIR="$audit_dir" "$helper" --today 2026-05-29 --from 2026-05-28 --to 2026-05-28)"
assert_jq "$dry_json" '.contract_version == "jen-morning-due-adjust.v1" and .status == "ok" and .mode == "dry-run" and .complete == true' 'dry-run output shape'
assert_jq "$dry_json" '.summary.total_classified == 5 and .summary.write_count == 0 and .summary.candidate_count == 1 and .summary.blocked_count == 4' 'dry-run summary counts'
assert_jq "$dry_json" '.candidates[] | select(.id == "soft-1" and .planned_action == "update-due" and .planned_due == "2026-05-29" and .deadline == null)' 'soft surface candidate re-anchors to today and has no deadline'
assert_jq "$dry_json" 'all(.blocked[]; .classification.category != "soft_surface")' 'non-soft categories are blocked from mutation'
[[ ! -s "$runtime_log" ]] || fail "dry-run must not call jen-task-runtime mutations"
[[ ! -e "$audit_dir" ]] || fail "dry-run must not write audit logs"

if JEN_MORNING_DUE_ADJUST_SEMANTICS="$mock_semantics" JEN_MORNING_DUE_ADJUST_TASK_RUNTIME="$mock_runtime" JEN_MORNING_TEST_SEMANTICS_LOG="$sem_log" JEN_MORNING_TEST_RUNTIME_LOG="$runtime_log" JEN_MORNING_DUE_ADJUST_AUDIT_DIR="$audit_dir" "$helper" --apply --today 2026-05-29 --from 2026-05-28 --to 2026-05-28 >"$mock_dir/apply-disabled.json"; then
  fail "apply without enable env must fail closed"
fi
assert_jq "$(cat "$mock_dir/apply-disabled.json")" '.status == "failed" and .failure_class == "apply_disabled" and .summary.write_count == 0' 'apply disabled failure is contract JSON with zero writes'

apply_json="$(JEN_MORNING_DUE_ADJUST_ENABLE_APPLY=1 JEN_MORNING_DUE_ADJUST_SEMANTICS="$mock_semantics" JEN_MORNING_DUE_ADJUST_TASK_RUNTIME="$mock_runtime" JEN_MORNING_TEST_SEMANTICS_LOG="$sem_log" JEN_MORNING_TEST_RUNTIME_LOG="$runtime_log" JEN_MORNING_DUE_ADJUST_AUDIT_DIR="$audit_dir" "$helper" --apply --today 2026-05-29 --from 2026-05-28 --to 2026-05-28)"
assert_jq "$apply_json" '.mode == "apply" and .summary.write_count == 1 and .writes[0].id == "soft-1" and .writes[0].operation == "update-due" and .writes[0].due == "2026-05-29" and .audit_log_path != null' 'enabled apply writes only soft candidate and records audit path'
[[ "$(grep -c '^update-due --task-id soft-1 --due 2026-05-29$' "$runtime_log")" == "1" ]] || fail "apply must call update-due once for soft candidate"
[[ "$(grep -Ec 'hard-1|rec-hard-1|rec-maint-1|amb-1' "$runtime_log" || true)" == "0" ]] || fail "apply must not mutate hard/recurring/ambiguous tasks"
[[ -f "$(jq -r '.audit_log_path' <<<"$apply_json")" ]] || fail "apply must create audit log file"
assert_jq "$(cat "$(jq -r '.audit_log_path' <<<"$apply_json")")" '.contract_version == "jen-morning-due-adjust.audit.v1" and .mode == "apply" and .status == "ok" and .writes[0].id == "soft-1"' 'audit log records applied write'

repeat_apply_json="$(JEN_MORNING_DUE_ADJUST_ENABLE_APPLY=1 JEN_MORNING_DUE_ADJUST_SEMANTICS="$mock_semantics" JEN_MORNING_DUE_ADJUST_TASK_RUNTIME="$mock_runtime" JEN_MORNING_TEST_SEMANTICS_LOG="$sem_log" JEN_MORNING_TEST_RUNTIME_LOG="$runtime_log" JEN_MORNING_DUE_ADJUST_AUDIT_DIR="$audit_dir" "$helper" --apply --today 2026-05-29 --from 2026-05-28 --to 2026-05-28)"
assert_jq "$repeat_apply_json" '.summary.write_count == 0 and .summary.skipped_count == 1 and .skipped[0].reason == "idempotency_key_already_succeeded"' 'repeat apply is idempotent and performs zero duplicate writes'
[[ "$(grep -c '^update-due --task-id soft-1 --due 2026-05-29$' "$runtime_log")" == "1" ]] || fail "idempotent repeat must not call update-due again"

if JEN_MORNING_DUE_ADJUST_ENABLE_APPLY=1 JEN_MORNING_DUE_ADJUST_MAX_CANDIDATES=0 JEN_MORNING_DUE_ADJUST_SEMANTICS="$mock_semantics" JEN_MORNING_DUE_ADJUST_TASK_RUNTIME="$mock_runtime" JEN_MORNING_TEST_SEMANTICS_LOG="$sem_log" JEN_MORNING_TEST_RUNTIME_LOG="$runtime_log" JEN_MORNING_DUE_ADJUST_AUDIT_DIR="$audit_dir" "$helper" --apply --soft-action clear --today 2026-05-29 --from 2026-05-28 --to 2026-05-28 >"$mock_dir/too-many.json"; then
  fail "apply above max candidates must fail closed"
fi
assert_jq "$(cat "$mock_dir/too-many.json")" '.status == "failed" and .failure_class == "too_many_candidates" and .summary.write_count == 0' 'candidate cap fails closed before writes'

clear_json="$(JEN_MORNING_DUE_ADJUST_ENABLE_APPLY=1 JEN_MORNING_DUE_ADJUST_SEMANTICS="$mock_semantics" JEN_MORNING_DUE_ADJUST_TASK_RUNTIME="$mock_runtime" JEN_MORNING_TEST_SEMANTICS_LOG="$sem_log" JEN_MORNING_TEST_RUNTIME_LOG="$runtime_log" JEN_MORNING_DUE_ADJUST_AUDIT_DIR="$audit_dir" "$helper" --apply --soft-action clear --today 2026-05-29 --from 2026-05-28 --to 2026-05-28)"
assert_jq "$clear_json" '.writes[0].operation == "clear-due" and .writes[0].runtime_command == "update-due" and .writes[0].due == "no date"' 'clear action clears due through approved runtime update-due no-date path'
[[ "$(grep -c '^update-due --task-id soft-1 --due no date$' "$runtime_log")" == "1" ]] || fail "clear action must use runtime update-due no date once"

move_json="$(JEN_MORNING_DUE_ADJUST_ENABLE_APPLY=1 JEN_MORNING_DUE_ADJUST_SEMANTICS="$mock_semantics" JEN_MORNING_DUE_ADJUST_TASK_RUNTIME="$mock_runtime" JEN_MORNING_TEST_SEMANTICS_LOG="$sem_log" JEN_MORNING_TEST_RUNTIME_LOG="$runtime_log" JEN_MORNING_DUE_ADJUST_AUDIT_DIR="$audit_dir" "$helper" --apply --soft-action move --project-id proj-week --today 2026-05-29 --from 2026-05-28 --to 2026-05-28)"
assert_jq "$move_json" '.writes[0].operation == "move-task" and .writes[0].project_id == "proj-week"' 'move action uses approved runtime move-task path'
[[ "$(grep -c '^move-task --task-id soft-1 --project-id proj-week$' "$runtime_log")" == "1" ]] || fail "move action must call runtime move-task once"

echo "jen-morning-due-adjust-contract: ok"
