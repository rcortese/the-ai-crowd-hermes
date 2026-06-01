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
# than a separate time-based job. This preserves ordering even if the schedule
# for the main morning hygiene job changes.
RECURRING_RUNNER="${JEN_MORNING_RECURRING_RUNNER:-/opt/data/scripts/jen-morning-recurring-maintenance-reanchor.sh}"
if [[ "${JEN_MORNING_RECURRING_REANCHOR_ENABLED:-1}" == "1" && "$mode" == "apply" && -x "$RECURRING_RUNNER" ]]; then
  "$RECURRING_RUNNER"
fi

candidate_count="$(jq -r '.result.summary.candidate_count // 0' "$packet")"
blocked_count="$(jq -r '.result.summary.blocked_count // 0' "$packet")"
write_count="$(jq -r '.result.summary.write_count // 0' "$packet")"
skipped_count="$(jq -r '.result.summary.skipped_count // 0' "$packet")"

# Stay quiet on normal zero-write runs. no-agent cron sends non-empty stdout.
if [[ "$candidate_count" != "0" || "$write_count" != "0" || "$skipped_count" != "0" ]]; then
  printf 'Jen morning soft-due hygiene %s: candidates=%s blocked=%s writes=%s skipped=%s packet=%s\n' "$mode" "$candidate_count" "$blocked_count" "$write_count" "$skipped_count" "$packet"
fi
