#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="$ROOT/tools/cron-scripts/jen-morning-recurring-maintenance-reanchor.sh"
fail() { echo "assertion failed: $*" >&2; exit 1; }
assert_jq() { local json="$1" filter="$2" message="$3"; jq -e "$filter" <<<"$json" >/dev/null || { echo "assertion failed: $message" >&2; echo "$json" >&2; exit 1; }; }
[[ -x "$helper" ]] || fail "missing executable helper"
mock_dir="$(mktemp -d)"
trap 'rm -rf "$mock_dir"' EXIT
space_dir="$mock_dir/path with spaces"
mkdir -p "$space_dir"
sem="$space_dir/mock semantics"
runtime="$space_dir/mock runtime"
state="$mock_dir/state"
sem_log="$mock_dir/sem.log"
rt_log="$mock_dir/rt.log"
cat > "$sem" <<'MOCKSEM'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$SEM_LOG"
jq -nc '{status:"ok",tasks:[
{id:"rec-1",content:"Cortar unha",due:{date:"2026-05-28",string:"toda semana",is_recurring:true},deadline:null,past_due_raw:true,evidence:{recurring_due:true},classification:{category:"recurring_maintenance"}},
{id:"rec-strong-single",content:"pagar qualquer coisa",due:{date:"2026-05-28",string:"todo mês",is_recurring:true},deadline:null,past_due_raw:true,evidence:{recurring_due:true,strong_hard_cues:["pagar"]},classification:{category:"ambiguous"}},
{id:"rec-strong-hard",content:"pagar boleto condominio",due:{date:"2026-05-28",string:"todo mês",is_recurring:true},deadline:null,past_due_raw:true,evidence:{recurring_due:true,strong_hard_cues:["pagar","boleto"]},classification:{category:"recurring_hard_obligation"}},
{id:"rec-no-string",content:"Bad recurring",due:{date:"2026-05-28",is_recurring:true},deadline:null,past_due_raw:true,evidence:{recurring_due:true},classification:{category:"recurring_maintenance"}},
{id:"deadline-rec",content:"Luz - Enel",due:{date:"2026-05-28",string:"todo mês",is_recurring:true},deadline:{date:"2026-06-05"},past_due_raw:true,evidence:{explicit_deadline:true},classification:{category:"hard_deadline"}},
{id:"soft-1",content:"tomar conta do grow",due:{date:"2026-05-28",is_recurring:false},deadline:null,past_due_raw:true,evidence:{ambiguous_cues:["conta"]},classification:{category:"soft_surface"}}
]}'
MOCKSEM
chmod +x "$sem"
cat > "$runtime" <<'MOCKRT'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$RT_LOG"
[[ "$*" == "update-due --task-id rec-1 --due toda semana" ]] || { jq -nc '{status:"failed",failure_class:"unexpected_args"}'; exit 1; }
jq -nc '{status:"ok",task:{id:"rec-1",due:{string:"toda semana",is_recurring:true}},verified:true}'
MOCKRT
chmod +x "$runtime"
TZ=UTC JEN_MORNING_RECURRING_RUN_ID=test-run JEN_MORNING_RECURRING_STATE_DIR="$state" JEN_MORNING_RECURRING_SEMANTICS="$sem" JEN_MORNING_RECURRING_TASK_RUNTIME="$runtime" SEM_LOG="$sem_log" RT_LOG="$rt_log" "$helper" >/tmp/recurring.out
packet="$(cat "$state/latest.json")"
assert_jq "$packet" '.contract_version == "jen-morning-recurring-maintenance-reanchor.v2" and .status == "ok" and .boundaries.max_candidates == 25 and .summary.candidate_count == 1 and .summary.write_count == 1' 'packet shape, cap, and write count'
assert_jq "$packet" '.writes[0].task.id == "rec-1" and .writes[0].due_string == "toda semana" and .writes[0].runtime_result.task.due.is_recurring == true' 'preserves due.string recurrence'
assert_jq "$packet" '.skipped[] | select(.id == "deadline-rec" and .skipped_reason == "has_deadline")' 'deadline-bearing recurring task skipped'
assert_jq "$packet" '.skipped[] | select(.id == "rec-strong-single" and .skipped_reason == "not_recurring_maintenance" and .classification.category == "ambiguous")' 'recurring standalone strong cue skipped, not reanchored'
assert_jq "$packet" '.skipped[] | select(.id == "rec-strong-hard" and .skipped_reason == "not_recurring_maintenance" and .classification.category == "recurring_hard_obligation")' 'recurring strong hard-cue combination skipped, not reanchored'
assert_jq "$packet" '.skipped[] | select(.id == "rec-no-string" and .skipped_reason == "missing_due_string")' 'missing due string skipped'
[[ "$(cat "$rt_log")" == "update-due --task-id rec-1 --due toda semana" ]] || fail "runtime called only for eligible recurring task"

rm -rf "$state"; mkdir -p "$state"
if TZ=UTC JEN_MORNING_RECURRING_MAX_CANDIDATES=0 JEN_MORNING_RECURRING_RUN_ID=test-cap JEN_MORNING_RECURRING_STATE_DIR="$state" JEN_MORNING_RECURRING_SEMANTICS="$sem" JEN_MORNING_RECURRING_TASK_RUNTIME="$runtime" SEM_LOG="$sem_log" RT_LOG="$rt_log" "$helper" >"$mock_dir/cap.out" 2>"$mock_dir/cap.err"; then
  fail "cap overflow must fail closed"
fi
cap_packet="$(cat "$state/latest.json")"
assert_jq "$cap_packet" '.status == "failed" and .failure_class == "too_many_candidates" and .summary.write_count == 0 and .boundaries.fail_closed_on_cap == true' 'cap overflow failure packet'
[[ "$(grep -c "update-due --task-id rec-1" "$rt_log")" == "1" ]] || fail "cap failure must not add runtime writes"
echo "jen-morning-recurring-maintenance-reanchor-contract: ok"
