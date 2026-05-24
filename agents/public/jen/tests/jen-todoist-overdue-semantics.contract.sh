#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "assertion failed: $*" >&2
  exit 1
}

require_fixed() {
  local file="$1" text="$2"
  grep -Fq "$text" "$ROOT/$file" || fail "missing expected contract text in $file: $text"
}

forbid_fixed() {
  local file="$1" text="$2"
  if grep -Fq "$text" "$ROOT/$file"; then
    fail "forbidden text remains in $file: $text"
  fi
}

# Raw provider/date state is not semantic lateness.
require_fixed docs/architecture/todoist-model.md '`past_due_raw` is a date signal, not yet a behavioral conclusion that Rodolfo is late'
require_fixed docs/architecture/todoist-model.md 'Before Jen mentions Todoist due, overdue, or past-date items in user-facing guidance, classify each surfaced item as one of the following categories. Use `bin/jen-todoist-due-semantics` as the executable classification surface when live due-window or task-like JSON evidence is available:'
require_fixed docs/architecture/todoist-model.md 'bin/jen-todoist-due-semantics'
require_fixed docs/architecture/signal-reconciliation.md 'raw Todoist due date, overdue flag, or past-date window'
require_fixed docs/architecture/integrated-awareness-model.md 'items with past dates'
require_fixed docs/architecture/integrated-awareness-model.md 'must be classified before Jen treats them as late work'
forbid_fixed docs/architecture/integrated-awareness-model.md 'due pressure, overdue work'

# Required classification categories.
for category in '`hard_deadline`' '`recurring_hard_obligation`' '`recurring_maintenance`' '`soft_surface`' '`ambiguous`'; do
  require_fixed docs/architecture/todoist-model.md "$category"
  require_fixed docs/flows/daily-flow.md "$category"
  require_fixed docs/flows/canonical-message-patterns.md "$category"
  require_fixed docs/flows/task-review.md "$category"
done

# Mandatory neutral wording and restricted lateness wording.
require_fixed docs/architecture/todoist-model.md 'When semantics are unclear, use neutral wording such as "items with past dates"'
require_fixed docs/flows/canonical-message-patterns.md 'Use "items with past dates" / "itens com data passada" when Todoist semantics are unclear.'
require_fixed docs/flows/canonical-message-patterns.md 'Use "late", "overdue", or "atrasado" only for established `hard_deadline` items.'
require_fixed docs/flows/task-review.md 'use "items with past dates" / "itens com data passada" for unclear Todoist semantics; reserve "atrasado" for established hard deadlines'
require_fixed docs/flows/daily-flow.md 'Treat raw Todoist overdue as "items with past dates" until semantics are clear'
require_fixed docs/architecture/todoist-model.md 'Never overwrite a recurring due date with a fixed/non-recurring date as part of soft-deadline cleanup.'
require_fixed docs/references/todoist-ops-contract.md 'Do not overwrite a recurring due date with a fixed/non-recurring date during soft-deadline cleanup or bulk date edits.'

# Category-specific actions, not only category names.
require_fixed docs/architecture/todoist-model.md '`hard_deadline`: a real-world deadline or commitment with external consequence'
require_fixed docs/architecture/todoist-model.md 'Action: do it, renegotiate it, reschedule it explicitly, or set/verify `deadline` when supported.'
require_fixed docs/architecture/todoist-model.md '`recurring_hard_obligation`: a recurring intended-execution cadence for an obligation with external consequence'
require_fixed docs/architecture/todoist-model.md 'Action: preserve recurrence in `due`; compute/read/update current-cycle `deadline` from the current `due.date` and explicit rule, or ask when not computable.'
require_fixed docs/architecture/todoist-model.md '`recurring_maintenance`: a cadence of care or upkeep'
require_fixed docs/architecture/todoist-model.md 'Action: choose the next viable occurrence or re-anchor the cadence'
require_fixed docs/architecture/todoist-model.md '`soft_surface`: a date used to bring work back into current attention'
require_fixed docs/architecture/todoist-model.md 'Action: decide whether to keep it today, move it to the configured near-horizon bucket such as `Esta Semana`, or remove the due date.'
require_fixed docs/architecture/todoist-model.md '`ambiguous`: insufficient evidence to classify the date semantics'
require_fixed docs/architecture/todoist-model.md 'Action: ask one focused question or suggest a short review'
require_fixed docs/flows/daily-flow.md '`hard_deadline`: do it, renegotiate it, reschedule it explicitly, or set/verify deadline.'
require_fixed docs/flows/daily-flow.md '`recurring_hard_obligation`: preserve the recurring `due` as intended execution/cadence and verify or update the current-cycle `deadline` from policy.'
require_fixed docs/flows/daily-flow.md '`recurring_maintenance`: choose the next viable occurrence or re-anchor the cadence.'
require_fixed docs/flows/daily-flow.md '`soft_surface`: keep it today, move it to the near-horizon bucket such as `Esta Semana`, or remove the due date.'
require_fixed docs/flows/daily-flow.md '`ambiguous`: ask one focused question or suggest a short review.'
require_fixed docs/flows/canonical-message-patterns.md 'hard deadline → do/renegotiate/reschedule/set or verify deadline; recurring hard obligation → preserve recurring due and verify/update current-cycle deadline from policy; recurring maintenance → choose next viable occurrence/re-anchor; soft surface → keep today/move to `Esta Semana`/remove due date; ambiguous → ask or suggest a short review.'
require_fixed docs/flows/task-review.md 'hard deadline → do/renegotiate/reschedule/set or verify deadline; recurring hard obligation → preserve recurring due and verify/update current-cycle deadline from policy; recurring maintenance → choose next viable occurrence/re-anchor; soft surface → keep today/move to `Esta Semana`/remove due date; ambiguous → ask or suggest a short review'

# Generic guilt/past-date language is forbidden unless a hard deadline is established.
require_fixed docs/flows/canonical-message-patterns.md 'generic past-date framing like "atrasados", "overdue pile", "zerar atrasados", or "você acumulou pendências" when the item is not an established hard deadline'
require_fixed docs/flows/daily-flow.md 'avoid "atrasado", "late", "overdue", or guilt wording like "clearing overdue tasks" unless a real missed obligation is established'

# Existing older morning contract should also point at the stronger semantics so regressions are caught from both surfaces.
require_fixed tests/jen-morning-copy-contract.sh 'Due/overdue language must avoid guilt by default while still preserving accountability.'



helper="$ROOT/bin/jen-todoist-due-semantics"

assert_jq() {
  local json="$1" filter="$2" message="$3"
  if ! jq -e "$filter" <<<"$json" >/dev/null; then
    echo "assertion failed: $message" >&2
    echo "$json" >&2
    exit 1
  fi
}

fixture='[
  {"id":"recurring-1","content":"Weekly review","due":{"date":"2026-04-27","string":"every monday","is_recurring":true}},
  {"id":"recurring-hard-1","content":"Pagar condomínio","due":{"date":"2026-04-27","string":"todo mês dia 5","is_recurring":true},"deadline":{"date":"2026-04-30"}},
  {"id":"bill-1","content":"Pagar boleto do condomínio","due":{"date":"2026-04-27","string":"yesterday","is_recurring":false}},
  {"id":"surface-1","content":"Review someday project note","due":{"date":"2026-04-27","string":"yesterday","is_recurring":false}},
  {"id":"ambiguous-1","content":"","due":null}
]'

classified="$(printf '%s\n' "$fixture" | "$helper" classify --today 2026-04-28)"
assert_jq "$classified" '.contract_version == "jen-todoist-due-semantics.v1" and .status == "ok" and .source == "stdin" and .complete == true' 'helper classify output shape'
assert_jq "$classified" '.summary.task_count == 5 and .summary.category_counts.recurring_maintenance == 1 and .summary.category_counts.recurring_hard_obligation == 1 and .summary.category_counts.hard_deadline == 1 and .summary.category_counts.soft_surface == 1 and .summary.category_counts.ambiguous == 1' 'helper category summary'
assert_jq "$classified" '.tasks[] | select(.id == "recurring-1" and .classification.category == "recurring_maintenance" and .classification.confidence == "high" and .past_due_raw == true)' 'recurring due classified as maintenance'
assert_jq "$classified" '.tasks[] | select(.id == "recurring-hard-1" and .classification.category == "recurring_hard_obligation" and .classification.confidence == "high" and .past_due_raw == true and .deadline.date == "2026-04-30" and (.classification.suggested_action | contains("current-cycle deadline")))' 'recurring hard obligation preserves due cadence and deadline cutoff semantics'
assert_jq "$classified" '.tasks[] | select(.id == "bill-1" and .classification.category == "hard_deadline" and .past_due_raw == true)' 'bill-like task classified as hard deadline'
assert_jq "$classified" '.tasks[] | select(.id == "surface-1" and .past_due_raw == true and .classification.category != "hard_deadline")' 'generic past-date task is not hard deadline'
assert_jq "$classified" '.tasks[] | select(.id == "ambiguous-1" and .classification.category == "ambiguous" and .classification.confidence == "low")' 'missing evidence is ambiguous'
assert_jq "$classified" '.tasks[] | select(.id == "recurring-1" and .deadline == null)' 'tasks without Todoist deadline preserve explicit null deadline'
assert_jq "$classified" 'all(.tasks[]; (.classification.category | IN("hard_deadline", "recurring_hard_obligation", "recurring_maintenance", "soft_surface", "ambiguous")) and (.classification.confidence | IN("high", "medium", "low")) and ((.classification.reason | length) > 0) and ((.classification.suggested_action | length) > 0))' 'every classification has required fields'

mock_dir=$(mktemp -d)
trap 'rm -rf "$mock_dir"' EXIT
mock_runtime="$mock_dir/jen-task-runtime"
call_log="$mock_dir/calls.log"
cat > "$mock_runtime" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${JEN_DUE_SEMANTICS_TEST_CALL_LOG:?}"
if [[ "$*" != "read-due-window --from 2026-04-27 --to 2026-04-29" ]]; then
  jq -nc '{contract_version:"jen-task-runtime.v1",command:"unexpected",status:"failed",failure_class:"unexpected_command"}'
  exit 1
fi
jq -nc '{contract_version:"jen-task-runtime.v1",command:"read-due-window",status:"ok",source:"live",from:"2026-04-27",to:"2026-04-29",tasks:[{id:"live-1",content:"Review surfaced item",due:{date:"2026-04-27",is_recurring:false}}],summary:{task_count:1},complete:true}'
EOF
chmod +x "$mock_runtime"
live_json="$(JEN_TODOIST_DUE_SEMANTICS_TASK_RUNTIME="$mock_runtime" JEN_DUE_SEMANTICS_TEST_CALL_LOG="$call_log" "$helper" live-due-window --from 2026-04-27 --to 2026-04-29 --today 2026-04-28)"
assert_jq "$live_json" '.status == "ok" and .source == "live" and .from == "2026-04-27" and .to == "2026-04-29" and .tasks[0].past_due_raw == true' 'live due window classifies runtime tasks'
if [[ "$(cat "$call_log")" != "read-due-window --from 2026-04-27 --to 2026-04-29" ]]; then
  echo "assertion failed: helper live mode must call only jen-task-runtime read-due-window" >&2
  cat "$call_log" >&2
  exit 1
fi

if grep -q 'todoist-api\.sh' "$helper"; then
  echo 'assertion failed: helper must not call raw todoist provider adapter' >&2
  exit 1
fi
mutation_patterns=(
  "capture-task"
  "update-due"
  "clear-due"
  "move-task"
  "update-labels"
  "close-task"
  "reopen-task"
  "clean-overdue-nonreal"
  "add-task"
  "update-task"
)
for pattern in "${mutation_patterns[@]}"; do
  if grep -q "\\b$pattern\\b" "$helper"; then
    echo "assertion failed: helper mentions mutation-capable command: $pattern" >&2
    exit 1
  fi
done

echo "jen-todoist-overdue-semantics-contract: ok"
