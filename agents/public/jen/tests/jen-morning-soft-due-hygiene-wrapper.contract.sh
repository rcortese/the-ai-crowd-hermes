#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runner="$ROOT/tools/cron-scripts/jen-morning-soft-due-hygiene.sh"
fail() { echo "assertion failed: $*" >&2; exit 1; }
assert_jq() { local json="$1" filter="$2" message="$3"; jq -e "$filter" <<<"$json" >/dev/null || { echo "assertion failed: $message" >&2; echo "$json" >&2; exit 1; }; }
[[ -f "$runner" ]] || fail "missing source-controlled morning soft-due hygiene wrapper"
bash -n "$runner" || fail "wrapper syntax"
state="$(mktemp -d)"
mock_dir="$(mktemp -d)"
trap 'rm -rf "$state" "$mock_dir"' EXIT
wrapper_log="$mock_dir/wrapper.log"
recurring_log="$mock_dir/recurring.log"
runtime_log="$mock_dir/runtime.log"
mock_wrapper="$mock_dir/jen-morning-due-adjust"
mock_runtime="$mock_dir/jen-task-runtime"
mock_recurring="$mock_dir/jen-morning-recurring-maintenance-reanchor.sh"
cat >"$mock_wrapper" <<'MOCKWRAP'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${WRAPPER_LOG:?}"
if [[ "$*" == *"--dry-run"* ]]; then
  jq -nc '{contract_version:"jen-morning-due-adjust.v2",status:"ok",mode:"dry-run",summary:{candidate_count:0,blocked_count:0,write_count:0,skipped_count:0},blocked:[],audit_log_path:null}'
else
  jq -nc '{contract_version:"jen-morning-due-adjust.v2",status:"ok",mode:"apply",summary:{candidate_count:1,blocked_count:2,write_count:1,skipped_count:0},writes:[{id:"deadline-open-1",operation:"update-due",due:"2026-05-29",deadline:{date:"2026-05-30"}}],blocked:[{id:"deadline-open-1",content:"Luz - Enel",due:{date:"2026-05-28",is_recurring:false},deadline:{date:"2026-05-30"},past_due_raw:true,classification:{category:"hard_deadline"},signals:["past_due_raw","todoist_deadline_object"]},{id:"rec-maint-1",content:"Weekly review",due:{date:"2026-05-28",string:"every week",is_recurring:true},deadline:null,past_due_raw:true,classification:{category:"recurring_maintenance"},signals:["past_due_raw","todoist_recurring_due"]}],audit_log_path:null}'
fi
MOCKWRAP
chmod +x "$mock_wrapper"
cat >"$mock_runtime" <<'MOCKRUNTIME'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${RUNTIME_LOG:?}"
case "$*" in
  "update-due --task-id rec-maint-1 --due every week") jq -nc '{status:"ok",command:"update-due",task:{id:"rec-maint-1",due:{string:"every week",is_recurring:true}},verified:true}' ;;
  *) jq -nc '{status:"failed",failure_class:"unexpected_runtime_args"}'; exit 1 ;;
esac
MOCKRUNTIME
chmod +x "$mock_runtime"
cat >"$mock_recurring" <<'MOCKREC'
#!/usr/bin/env bash
set -euo pipefail
printf 'called\n' >> "${RECURRING_LOG:?}"
MOCKREC
chmod +x "$mock_recurring"
WRAPPER_LOG="$wrapper_log" RECURRING_LOG="$recurring_log" RUNTIME_LOG="$runtime_log" \
JEN_MORNING_SOFT_DUE_STATE_DIR="$state/dry" \
JEN_MORNING_SOFT_DUE_WRAPPER="$mock_wrapper" \
JEN_MORNING_RECURRING_TASK_RUNTIME="$mock_runtime" \
JEN_MORNING_RECURRING_RUNNER="$mock_recurring" \
JEN_MORNING_SOFT_DUE_HYGIENE_APPLY=0 \
JEN_MORNING_SOFT_DUE_TZ=UTC \
"$runner"
[[ ! -s "$recurring_log" ]] || fail "dry-run must not invoke legacy recurring runner"
[[ ! -s "$runtime_log" ]] || fail "dry-run must not mutate recurring tasks"
assert_jq "$(cat "$state/dry/latest.json")" '.status == "ok" and .mode == "dry-run" and .boundaries.dry_run_only == true and .boundaries.todoist_write_enabled == false and .boundaries.no_calendar_write == true and .boundaries.no_task_creation == true and .boundaries.no_provider_message == true' 'dry-run packet boundaries'
WRAPPER_LOG="$wrapper_log" RECURRING_LOG="$recurring_log" RUNTIME_LOG="$runtime_log" \
JEN_MORNING_SOFT_DUE_STATE_DIR="$state/apply" \
JEN_MORNING_SOFT_DUE_WRAPPER="$mock_wrapper" \
JEN_MORNING_RECURRING_TASK_RUNTIME="$mock_runtime" \
JEN_MORNING_RECURRING_STATE_DIR="$state/apply/morning-recurring-maintenance-reanchor" \
JEN_MORNING_RECURRING_RUNNER="$mock_recurring" \
JEN_MORNING_SOFT_DUE_HYGIENE_APPLY=1 \
JEN_MORNING_SOFT_DUE_TZ=UTC \
"$runner"
[[ ! -s "$recurring_log" ]] || fail "apply must not invoke the legacy second-live-read recurring runner"
[[ "$(grep -c '^update-due --task-id rec-maint-1 --due every week$' "$runtime_log")" == "1" ]] || fail "apply must reanchor recurring maintenance from the existing packet snapshot"
assert_jq "$(cat "$state/apply/morning-recurring-maintenance-reanchor/latest.json")" '.status == "ok" and .boundaries.source_snapshot_reused == true and .summary.write_count == 1 and .candidates[0].id == "rec-maint-1" and all(.candidates[]; .deadline == null) and any(.skipped[]; .id == "deadline-open-1" and .skipped_reason == "has_deadline")' 'recurring packet records source snapshot reuse and excludes deadline surfaces'
assert_jq "$(cat "$state/apply/latest.json")" '.status == "ok" and .mode == "apply" and .boundaries.dry_run_only == false and .boundaries.todoist_write_enabled == true and .boundaries.no_calendar_write == true and .boundaries.no_task_creation == true and .boundaries.no_provider_message == true' 'apply packet boundaries'
[[ "$(grep -c -- '--apply --soft-action today' "$wrapper_log")" == "1" ]] || fail "apply wrapper args include bounded apply action"
[[ "$(grep -c -- '--dry-run' "$wrapper_log")" == "1" ]] || fail "dry-run wrapper args include dry-run"
echo "jen-morning-soft-due-hygiene-wrapper-contract: ok"
