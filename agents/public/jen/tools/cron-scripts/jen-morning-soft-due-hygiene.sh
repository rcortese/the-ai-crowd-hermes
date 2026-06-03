#!/usr/bin/env bash
set -euo pipefail

# Morning soft-due hygiene runner for Jen.
# Scheduled operation applies bounded writes by default after Moss code review.
# The underlying wrapper still fails closed unless this script passes its apply
# gate invocation-scoped. Set JEN_MORNING_SOFT_DUE_HYGIENE_APPLY=0 for dry-run.

TZ_NAME="${JEN_MORNING_SOFT_DUE_TZ:-America/Sao_Paulo}"
STATE_DIR="${JEN_MORNING_SOFT_DUE_STATE_DIR:-/opt/data/state/jen-cron/morning-soft-due-hygiene}"
ARCHIVE_DIR="$STATE_DIR/archive"
WRAPPER="${JEN_MORNING_SOFT_DUE_WRAPPER:-/agents/jen/public/bin/jen-morning-due-adjust}"
RETENTION_DAYS="${JEN_MORNING_SOFT_DUE_RETENTION_DAYS:-30}"
APPLY_MODE="${JEN_MORNING_SOFT_DUE_HYGIENE_APPLY:-1}"
SOFT_ACTION="${JEN_MORNING_SOFT_DUE_ACTION:-today}"
MAX_CANDIDATES="${JEN_MORNING_SOFT_DUE_MAX_CANDIDATES:-25}"
LOOKBACK_DAYS="${JEN_MORNING_SOFT_DUE_LOOKBACK_DAYS:-14}"

mkdir -p "$STATE_DIR" "$ARCHIVE_DIR"

today="$(TZ="$TZ_NAME" date +%F)"
from_date="$(TZ="$TZ_NAME" date -d "$today -$LOOKBACK_DAYS days" +%F)"
to_date="$today"
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
run_id="jen-soft-due-${today}-$(date -u +%Y%m%dT%H%M%SZ)-$$"
mode="dry-run"
if [[ "$APPLY_MODE" == "1" ]]; then mode="apply"; fi
packet="$STATE_DIR/latest.json"
archive_packet="$ARCHIVE_DIR/${today}-$(date -u +%Y%m%dT%H%M%SZ).json"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

audit_dir="$STATE_DIR/audit"
idempotency_dir="$STATE_DIR/idempotency"
mkdir -p "$audit_dir" "$idempotency_dir"

if [[ "$mode" == "apply" ]]; then
  wrapper_cmd=(env JEN_MORNING_DUE_ADJUST_ENABLE_APPLY=1 JEN_MORNING_DUE_ADJUST_MAX_CANDIDATES="$MAX_CANDIDATES" JEN_MORNING_DUE_ADJUST_RUN_ID="$run_id" JEN_MORNING_DUE_ADJUST_AUDIT_DIR="$audit_dir" JEN_MORNING_DUE_ADJUST_IDEMPOTENCY_DIR="$idempotency_dir" "$WRAPPER" --apply --soft-action "$SOFT_ACTION" --today "$today" --from "$from_date" --to "$to_date")
else
  wrapper_cmd=(env JEN_MORNING_DUE_ADJUST_MAX_CANDIDATES="$MAX_CANDIDATES" JEN_MORNING_DUE_ADJUST_RUN_ID="$run_id" JEN_MORNING_DUE_ADJUST_AUDIT_DIR="$audit_dir" JEN_MORNING_DUE_ADJUST_IDEMPOTENCY_DIR="$idempotency_dir" "$WRAPPER" --dry-run --today "$today" --from "$from_date" --to "$to_date")
fi

if ! result="$("${wrapper_cmd[@]}")"; then
  printf '%s\n' "$result" > "$tmp" 2>/dev/null || true
  jq -nc \
    --arg contract_version jen-morning-soft-due-hygiene-run.v1 \
    --arg status degraded \
    --arg failure_class wrapper_failed \
    --arg mode "$mode" \
    --arg started_at "$started_at" \
    --arg completed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg date "$today" \
    --arg timezone "$TZ_NAME" \
    --arg from "$from_date" \
    --arg to "$to_date" \
    --arg wrapper "$WRAPPER" \
    --arg run_id "$run_id" \
    --arg raw "$(cat "$tmp" 2>/dev/null || true)" \
    '{contract_version:$contract_version,status:$status,failure_class:$failure_class,mode:$mode,started_at:$started_at,completed_at:$completed_at,date:$date,timezone:$timezone,from:$from,to:$to,wrapper:$wrapper,run_id:$run_id,boundaries:{dry_run_only:($mode == "dry-run"),todoist_write_enabled:($mode == "apply"),no_calendar_write:true,no_task_creation:true,no_provider_message:true},raw_output:$raw}' > "$packet"
  cp "$packet" "$archive_packet" 2>/dev/null || true
  printf '⚠️ Jen morning soft-due hygiene degraded. mode=%s date=%s packet=%s\n' "$mode" "$today" "$packet"
  exit 1
fi

printf '%s\n' "$result" > "$tmp"
if ! jq empty "$tmp" >/dev/null 2>&1; then
  jq -nc \
    --arg contract_version jen-morning-soft-due-hygiene-run.v1 \
    --arg status degraded \
    --arg failure_class invalid_json \
    --arg mode "$mode" \
    --arg started_at "$started_at" \
    --arg completed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg date "$today" \
    --arg timezone "$TZ_NAME" \
    --arg from "$from_date" \
    --arg to "$to_date" \
    --arg wrapper "$WRAPPER" \
    --arg run_id "$run_id" \
    --arg raw "$(cat "$tmp")" \
    '{contract_version:$contract_version,status:$status,failure_class:$failure_class,mode:$mode,started_at:$started_at,completed_at:$completed_at,date:$date,timezone:$timezone,from:$from,to:$to,wrapper:$wrapper,run_id:$run_id,boundaries:{dry_run_only:($mode == "dry-run"),todoist_write_enabled:($mode == "apply"),no_calendar_write:true,no_task_creation:true,no_provider_message:true},raw_output:$raw}' > "$packet"
  cp "$packet" "$archive_packet" 2>/dev/null || true
  printf '⚠️ Jen morning soft-due hygiene returned invalid JSON. mode=%s date=%s packet=%s\n' "$mode" "$today" "$packet"
  exit 1
fi

jq -c \
  --arg contract_version jen-morning-soft-due-hygiene-run.v1 \
  --arg status ok \
  --arg mode "$mode" \
  --arg started_at "$started_at" \
  --arg completed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg date "$today" \
  --arg timezone "$TZ_NAME" \
  --arg from "$from_date" \
  --arg to "$to_date" \
  --arg wrapper "$WRAPPER" \
  --arg run_id "$run_id" \
  '{contract_version:$contract_version,status:$status,mode:$mode,started_at:$started_at,completed_at:$completed_at,date:$date,timezone:$timezone,from:$from,to:$to,wrapper:$wrapper,run_id:$run_id,boundaries:{dry_run_only:($mode == "dry-run"),todoist_write_enabled:($mode == "apply"),no_calendar_write:true,no_task_creation:true,no_provider_message:true},result:.}' "$tmp" > "$packet"
cp "$packet" "$archive_packet"
find "$ARCHIVE_DIR" -maxdepth 1 -type f -name '*.json' -mtime +"$RETENTION_DAYS" -delete 2>/dev/null || true

# Keep recurring maintenance re-anchoring coupled to this cron execution rather
# than a separate time-based job. Reuse the already-classified wrapper result so
# the morning cron does not perform a second live Todoist read and exceed the
# scheduler timeout after non-recurring writes have already succeeded.
reanchor_recurring_from_packet() {
  local task_runtime="${JEN_MORNING_RECURRING_TASK_RUNTIME:-/agents/jen/public/bin/jen-task-runtime}"
  local recurring_state_dir="${JEN_MORNING_RECURRING_STATE_DIR:-/opt/data/state/jen-cron/morning-recurring-maintenance-reanchor}"
  local recurring_audit_dir="$recurring_state_dir/audit"
  local recurring_max="${JEN_MORNING_RECURRING_MAX_CANDIDATES:-25}"
  local recurring_packet="$recurring_state_dir/latest.json"
  local recurring_audit="$recurring_audit_dir/$(date -u +%Y%m%dT%H%M%SZ)-jen-recurring-maint-${today}-from-soft-due-${run_id}.json"
  local recurring_tmp writes_file candidates skipped candidate_count idx task task_id due_string result tmpw status write_count failure_count

  [[ "$recurring_max" =~ ^[0-9]+$ ]] || return 2
  [[ -x "$task_runtime" ]] || return 2
  mkdir -p "$recurring_state_dir" "$recurring_audit_dir"
  recurring_tmp="$(mktemp)"
  writes_file="$(mktemp)"
  printf '[]\n' > "$writes_file"

  candidates="$(jq -c '[.result.blocked[]? | select(.past_due_raw == true and .classification.category == "recurring_maintenance" and (.deadline == null) and (.due.is_recurring == true) and ((.due.string // "") != "")) | {id,content,due_string:.due.string,due:.due,deadline,evidence:(.evidence // null),classification,signals:(.signals // [])}]' "$packet")"
  skipped="$(jq -c '[.result.blocked[]? | select((.past_due_raw != true) or (.classification.category != "recurring_maintenance") or (.deadline != null) or (.due.is_recurring != true) or ((.due.string // "") == "")) | {id,content,due:(.due // null),deadline:(.deadline // null),evidence:(.evidence // null),classification:(.classification // null),signals:(.signals // []),skipped_reason:(if .past_due_raw != true then "not_past_due" elif .deadline != null then "has_deadline" elif .due.is_recurring != true then "not_recurring" elif ((.due.string // "") == "") then "missing_due_string" else "not_recurring_maintenance" end)}]' "$packet")"
  candidate_count="$(jq 'length' <<<"$candidates")"

  write_recurring_packet() {
    local packet_status="$1" failure_class="${2:-}" writes_json
    writes_json="$(cat "$writes_file")"
    jq -nc \
      --arg contract_version jen-morning-recurring-maintenance-reanchor.v3 \
      --arg run_id "jen-recurring-maint-${today}-from-soft-due-${run_id}" \
      --arg date "$today" --arg from "$from_date" --arg to "$to_date" --arg mode apply \
      --arg status "$packet_status" --arg failure_class "$failure_class" \
      --arg source_packet "$packet" --arg audit_log_path "$recurring_audit" \
      --argjson max_candidates "$recurring_max" --argjson candidates "$candidates" --argjson skipped "$skipped" --argjson writes "$writes_json" '
        {
          contract_version:$contract_version,run_id:$run_id,date:$date,from:$from,to:$to,mode:$mode,status:$status,
          failure_class:(if $failure_class == "" then null else $failure_class end),source_packet:$source_packet,
          boundaries:{preserve_recurring_due:true,no_deadline_write:true,no_calendar_write:true,no_task_creation:true,no_provider_message:true,max_candidates:$max_candidates,fail_closed_on_cap:true,source_snapshot_reused:true},
          summary:{candidate_count:($candidates|length),skipped_count:($skipped|length),write_count:([ $writes[]? | select(.status == "ok") ] | length),failure_count:([ $writes[]? | select(.status != "ok") ] | length)},
          audit_log_path:$audit_log_path,candidates:$candidates,skipped:$skipped,writes:$writes,complete:($status == "ok")
        }' > "$recurring_tmp"
    mv "$recurring_tmp" "$recurring_packet"
    cp "$recurring_packet" "$recurring_audit" 2>/dev/null || true
  }

  if (( candidate_count > recurring_max )); then
    write_recurring_packet failed too_many_candidates
    rm -f "$writes_file"
    return 1
  fi

  write_recurring_packet in_progress
  idx=0
  while [[ "$idx" -lt "$candidate_count" ]]; do
    task="$(jq -c --argjson idx "$idx" '.[$idx]' <<<"$candidates")"
    task_id="$(jq -r '.id' <<<"$task")"
    due_string="$(jq -r '.due_string' <<<"$task")"
    tmpw="$(mktemp)"
    if result="$("$task_runtime" update-due --task-id "$task_id" --due "$due_string")" && jq -e '.status == "ok"' <<<"$result" >/dev/null; then
      jq --argjson task "$task" --argjson result "$result" '. + [{task:$task,status:"ok",operation:"reanchor-recurring-due",due_string:$task.due_string,runtime_result:$result}]' "$writes_file" > "$tmpw"
    else
      jq --argjson task "$task" '. + [{task:$task,status:"failed",operation:"reanchor-recurring-due",due_string:$task.due_string}]' "$writes_file" > "$tmpw"
    fi
    mv "$tmpw" "$writes_file"
    write_recurring_packet in_progress
    idx=$((idx + 1))
  done

  status="ok"
  if jq -e '[.[] | select(.status != "ok")] | length > 0' "$writes_file" >/dev/null; then status="degraded"; fi
  write_recurring_packet "$status"
  write_count="$(jq '[.[] | select(.status == "ok")] | length' "$writes_file")"
  failure_count="$(jq '[.[] | select(.status != "ok")] | length' "$writes_file")"
  rm -f "$writes_file"
  if [[ "$write_count" != "0" || "$failure_count" != "0" ]]; then
    printf 'Jen morning recurring maintenance reanchor: candidates=%s writes=%s failures=%s packet=%s\n' "$candidate_count" "$write_count" "$failure_count" "$recurring_packet"
  fi
  [[ "$status" == "ok" ]]
}

if [[ "${JEN_MORNING_RECURRING_REANCHOR_ENABLED:-1}" == "1" && "$mode" == "apply" ]]; then
  reanchor_recurring_from_packet
fi

candidate_count="$(jq -r '.result.summary.candidate_count // 0' "$packet")"
blocked_count="$(jq -r '.result.summary.blocked_count // 0' "$packet")"
write_count="$(jq -r '.result.summary.write_count // 0' "$packet")"
skipped_count="$(jq -r '.result.summary.skipped_count // 0' "$packet")"

# Stay quiet on normal zero-write runs. no-agent cron sends non-empty stdout.
if [[ "$candidate_count" != "0" || "$write_count" != "0" || "$skipped_count" != "0" ]]; then
  printf 'Jen morning soft-due hygiene %s: candidates=%s blocked=%s writes=%s skipped=%s packet=%s\n' "$mode" "$candidate_count" "$blocked_count" "$write_count" "$skipped_count" "$packet"
fi
