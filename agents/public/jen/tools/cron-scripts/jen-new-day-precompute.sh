#!/usr/bin/env bash
set -euo pipefail
STATE_DIR="${JEN_CRON_STATE_DIR:-/opt/data/state/jen-cron}"
PACKET="$STATE_DIR/wakeup-handoff.json"
ARCHIVE_DIR="$STATE_DIR/wakeup-handoff-archive"
TZ_NAME="${JEN_NEW_DAY_RESET_TZ:-America/Sao_Paulo}"
mkdir -p "$STATE_DIR" "$ARCHIVE_DIR"
today="$(TZ="$TZ_NAME" date +%F)"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [[ -s "$PACKET" ]] && jq empty "$PACKET" >/dev/null 2>&1; then
  old_date="$(jq -r '.date // empty' "$PACKET")"
  if [[ "$old_date" != "$today" ]]; then
    cp "$PACKET" "$ARCHIVE_DIR/${old_date:-unknown}-$(date -u +%Y%m%dT%H%M%SZ).stale.json" 2>/dev/null || true
    find "$ARCHIVE_DIR" -maxdepth 1 -type f -name '*.stale.json' -mtime +14 -delete 2>/dev/null || true
  fi
fi
from="$today"
to="$(TZ="$TZ_NAME" date -d "$today +1 day" +%F)"
tasks_file="$(mktemp)"; task_health_file="$(mktemp)"; cal_health_file="$(mktemp)"
trap 'rm -f "$tasks_file" "$task_health_file" "$cal_health_file"' EXIT
/agents/jen/public/bin/jen-task-read due-window --from "$from" --to "$to" >"$tasks_file" 2>/dev/null || true
/agents/jen/public/bin/jen-task-runtime health >"$task_health_file" 2>/dev/null || true
/agents/jen/public/tools/wrappers/jen-calendar-runtime health >"$cal_health_file" 2>/dev/null || true
jq empty "$tasks_file" >/dev/null 2>&1 || printf '{"status":"unknown","tasks":[]}' >"$tasks_file"
jq empty "$task_health_file" >/dev/null 2>&1 || printf '{"status":"degraded"}' >"$task_health_file"
jq empty "$cal_health_file" >/dev/null 2>&1 || printf '{"status":"degraded","live_read_status":"runtime_failure"}' >"$cal_health_file"
todoist_status="$(jq -r '.status // "unknown"' "$task_health_file")"
calendar_status="$(jq -r '.status // "unknown"' "$cal_health_file")"
calendar_live_read="$(jq -r '.live_read_status // "unknown"' "$cal_health_file")"
due_count="$(jq -r '.summary.task_count // (.tasks|length) // 0' "$tasks_file")"
status="ok"
[[ "$todoist_status" == "ok" ]] || status="degraded"
[[ "$calendar_status" == "ok" && "$calendar_live_read" == "ok" ]] || status="degraded"
packet="$(jq -nc \
  --arg contract_version jen-new-day-handoff.v1 \
  --arg generated_at "$now" \
  --arg date "$today" \
  --arg timezone "$TZ_NAME" \
  --arg status "$status" \
  --arg todoist_status "$todoist_status" \
  --arg calendar_status "$calendar_status" \
  --arg calendar_live_read_status "$calendar_live_read" \
  --argjson due_window "$(cat "$tasks_file")" \
  --argjson task_health "$(cat "$task_health_file")" \
  --argjson calendar_health "$(cat "$cal_health_file")" \
  --argjson due_count "$due_count" \
  '{contract_version:$contract_version,generated_at:$generated_at,date:$date,timezone:$timezone,status:$status,summary:{todoist_status:$todoist_status,calendar_status:$calendar_status,calendar_live_read_status:$calendar_live_read_status,due_window_task_count:$due_count},due_window:$due_window,task_health:$task_health,calendar_health:$calendar_health,boundaries:{no_calendar_write:true,no_task_creation:true,no_provider_message:true,no_cron_mutation:true}}')"
printf '%s\n' "$packet" >"$PACKET"
if [[ "$status" != "ok" ]]; then
  printf '⚠️ Jen new-day handoff precompute degraded. todoist_status=%s; calendar_status=%s; calendar_live_read_status=%s; date=%s; packet=%s\n' "$todoist_status" "$calendar_status" "$calendar_live_read" "$today" "$PACKET"
fi
