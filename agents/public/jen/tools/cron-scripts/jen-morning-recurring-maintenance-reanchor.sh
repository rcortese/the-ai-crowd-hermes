#!/usr/bin/env bash
set -euo pipefail

CONTRACT_VERSION="jen-morning-recurring-maintenance-reanchor.v2"
TZ_NAME="${JEN_MORNING_RECURRING_TZ:-America/Sao_Paulo}"
LOOKBACK_DAYS="${JEN_MORNING_RECURRING_LOOKBACK_DAYS:-14}"
MAX_CANDIDATES="${JEN_MORNING_RECURRING_MAX_CANDIDATES:-25}"
STATE_DIR="${JEN_MORNING_RECURRING_STATE_DIR:-/opt/data/state/jen-cron/morning-recurring-maintenance-reanchor}"
AUDIT_DIR="$STATE_DIR/audit"
SEMANTICS="${JEN_MORNING_RECURRING_SEMANTICS:-/agents/jen/public/bin/jen-todoist-due-semantics}"
TASK_RUNTIME="${JEN_MORNING_RECURRING_TASK_RUNTIME:-/agents/jen/public/bin/jen-task-runtime}"

valid_nonnegative_int() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }
write_packet() {
  local status="$1" failure_class="${2:-}" writes_json="${3:-[]}" candidates_json="${4:-[]}" skipped_json="${5:-[]}" classified_json="${6:-null}"
  jq -nc \
    --arg contract_version "$CONTRACT_VERSION" \
    --arg run_id "$run_id" \
    --arg date "$today" \
    --arg from "$from_date" \
    --arg to "$to_date" \
    --arg mode apply \
    --arg status "$status" \
    --arg failure_class "$failure_class" \
    --arg audit_log_path "$audit" \
    --argjson max_candidates "$MAX_CANDIDATES" \
    --argjson classified "$classified_json" \
    --argjson candidates "$candidates_json" \
    --argjson skipped "$skipped_json" \
    --argjson writes "$writes_json" '
      {
        contract_version:$contract_version,
        run_id:$run_id,
        date:$date,
        from:$from,
        to:$to,
        mode:$mode,
        status:$status,
        failure_class:(if $failure_class == "" then null else $failure_class end),
        boundaries:{
          preserve_recurring_due:true,
          no_deadline_write:true,
          no_calendar_write:true,
          no_task_creation:true,
          no_provider_message:true,
          max_candidates:$max_candidates,
          fail_closed_on_cap:true
        },
        summary:{
          total_classified:(if ($classified|type)=="object" and (($classified.tasks|type)=="array") then ($classified.tasks|length) else 0 end),
          candidate_count:($candidates|length),
          skipped_count:($skipped|length),
          write_count:([ $writes[]? | select(.status == "ok") ] | length),
          failure_count:([ $writes[]? | select(.status != "ok") ] | length)
        },
        audit_log_path:$audit_log_path,
        candidates:$candidates,
        skipped:$skipped,
        writes:$writes,
        classified:$classified,
        complete:($status == "ok")
      }' > "$packet"
  cp "$packet" "$audit" 2>/dev/null || true
}

mkdir -p "$STATE_DIR" "$AUDIT_DIR"
valid_nonnegative_int "$LOOKBACK_DAYS" || { echo "invalid JEN_MORNING_RECURRING_LOOKBACK_DAYS" >&2; exit 2; }
valid_nonnegative_int "$MAX_CANDIDATES" || { echo "invalid JEN_MORNING_RECURRING_MAX_CANDIDATES" >&2; exit 2; }
today="$(TZ="$TZ_NAME" date +%F)"
from_date="$(TZ="$TZ_NAME" date -d "$today -$LOOKBACK_DAYS days" +%F)"
to_date="$today"
run_id="${JEN_MORNING_RECURRING_RUN_ID:-jen-recurring-maint-${today}-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
packet="$STATE_DIR/latest.json"
audit="$AUDIT_DIR/$(date -u +%Y%m%dT%H%M%SZ)-$run_id.json"
writes_file="$(mktemp)"
trap 'rm -f "$writes_file"' EXIT
printf '[]\n' > "$writes_file"

if ! classified="$("$SEMANTICS" live-due-window --from "$from_date" --to "$to_date" --today "$today")"; then
  write_packet failed semantics_failed
  printf 'Jen morning recurring maintenance reanchor failed closed: semantics_failed packet=%s\n' "$packet" >&2
  exit 1
fi
if ! jq -e '.status == "ok" and (.tasks|type == "array")' <<<"$classified" >/dev/null; then
  write_packet failed semantics_invalid_shape '[]' '[]' '[]' "$classified"
  printf 'Jen morning recurring maintenance reanchor failed closed: semantics_invalid_shape packet=%s\n' "$packet" >&2
  exit 1
fi

candidates="$(jq -c '[.tasks[]? | select(.past_due_raw == true and .classification.category == "recurring_maintenance" and (.deadline == null) and (.due.is_recurring == true) and ((.due.string // "") != "")) | {id,content,due_string:.due.string,due:.due,deadline,evidence:(.evidence // null),classification,signals:(.signals // [])}]' <<<"$classified")"
skipped="$(jq -c '[.tasks[]? | select((.past_due_raw != true) or (.classification.category != "recurring_maintenance") or (.deadline != null) or (.due.is_recurring != true) or ((.due.string // "") == "")) | {id,content,due:(.due // null),deadline:(.deadline // null),evidence:(.evidence // null),classification:(.classification // null),signals:(.signals // []),skipped_reason:(if .past_due_raw != true then "not_past_due" elif .deadline != null then "has_deadline" elif .due.is_recurring != true then "not_recurring" elif ((.due.string // "") == "") then "missing_due_string" else "not_recurring_maintenance" end)}]' <<<"$classified")"
candidate_count="$(jq 'length' <<<"$candidates")"
if (( candidate_count > MAX_CANDIDATES )); then
  write_packet failed too_many_candidates '[]' "$candidates" "$skipped" "$classified"
  printf 'Jen morning recurring maintenance reanchor failed closed: candidates=%s max=%s packet=%s\n' "$candidate_count" "$MAX_CANDIDATES" "$packet" >&2
  exit 1
fi

write_packet in_progress '' '[]' "$candidates" "$skipped" "$classified"
while IFS= read -r task; do
  [[ -n "$task" ]] || continue
  task_id="$(jq -r '.id' <<<"$task")"
  due_string="$(jq -r '.due_string' <<<"$task")"
  new="$(mktemp)"
  if result="$("$TASK_RUNTIME" update-due --task-id "$task_id" --due "$due_string")" && jq -e '.status == "ok"' <<<"$result" >/dev/null; then
    jq --argjson task "$task" --argjson result "$result" '. + [{task:$task,status:"ok",operation:"reanchor-recurring-due",due_string:$task.due_string,runtime_result:$result}]' "$writes_file" > "$new"
  else
    jq --argjson task "$task" '. + [{task:$task,status:"failed",operation:"reanchor-recurring-due",due_string:$task.due_string}]' "$writes_file" > "$new"
  fi
  mv "$new" "$writes_file"
  write_packet in_progress '' "$(cat "$writes_file")" "$candidates" "$skipped" "$classified"
done < <(jq -c '.[]' <<<"$candidates")

status="ok"
if jq -e '[.[] | select(.status != "ok")] | length > 0' "$writes_file" >/dev/null; then status="degraded"; fi
write_packet "$status" '' "$(cat "$writes_file")" "$candidates" "$skipped" "$classified"
write_count="$(jq '[.[] | select(.status == "ok")] | length' "$writes_file")"
failure_count="$(jq '[.[] | select(.status != "ok")] | length' "$writes_file")"
if [[ "$write_count" != "0" || "$failure_count" != "0" ]]; then
  printf 'Jen morning recurring maintenance reanchor: candidates=%s writes=%s failures=%s packet=%s\n' "$candidate_count" "$write_count" "$failure_count" "$packet"
fi
[[ "$status" == "ok" ]]
