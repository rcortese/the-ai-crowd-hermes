#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="${JEN_CRON_STATE_DIR:-/opt/data/state/jen-cron}"
STATE_FILE="$STATE_DIR/calendar-facade-watch.json"
REPEAT_SECONDS="${JEN_CALENDAR_FACADE_WATCH_REPEAT_SECONDS:-21600}"
CALENDAR_RUNTIME_WRAPPER="${JEN_CALENDAR_RUNTIME_WRAPPER:-/agents/jen/public/tools/wrappers/jen-calendar-runtime}"
HERMES_CLI="${JEN_HERMES_CLI:-/opt/hermes/.venv/bin/hermes}"
REQUIRED_TOOLSET="${JEN_CALENDAR_REQUIRED_TOOLSET:-jen_calendar_process}"
TELEGRAM_PLATFORM="${JEN_CALENDAR_TELEGRAM_PLATFORM:-telegram}"
API_PLATFORM="${JEN_CALENDAR_API_PLATFORM:-api_server}"

mkdir -p "$STATE_DIR"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
health_file="$(mktemp)"
trap 'rm -f "$health_file"' EXIT

if ! "$CALENDAR_RUNTIME_WRAPPER" health >"$health_file" 2>/dev/null || ! jq empty "$health_file" >/dev/null 2>&1; then
  health="$(jq -nc --arg checked_at "$now" '{status:"degraded",live_read_status:"runtime_failure",checked_at:$checked_at}')"
else
  health="$(jq -c . "$health_file")"
fi

runtime_status="$(jq -r '.status // "degraded"' <<<"$health")"
live_read_status="$(jq -r '.live_read_status // "unknown"' <<<"$health")"
posture="$(jq -r '.posture // "unknown"' <<<"$health")"

check_tool_surface() {
  local platform="$1"
  local output
  if ! output="$($HERMES_CLI tools list --platform "$platform" 2>&1)"; then
    printf 'cli_error'
    return 0
  fi
  if printf '%s\n' "$output" | grep -Fq "$REQUIRED_TOOLSET"; then
    printf 'ok'
  else
    printf 'missing_toolset'
  fi
}

telegram_tool_status="$(check_tool_surface "$TELEGRAM_PLATFORM")"
api_tool_status="$(check_tool_surface "$API_PLATFORM")"

overall_status="ok"
if [[ "$runtime_status" != "ok" || "$live_read_status" != "ok" || "$telegram_tool_status" != "ok" || "$api_tool_status" != "ok" ]]; then
  overall_status="degraded"
fi

first_failure_at=""
last_alert_at=""
last_ok_at=""
previous_status=""
if [[ -f "$STATE_FILE" ]] && jq empty "$STATE_FILE" >/dev/null 2>&1; then
  first_failure_at="$(jq -r '.first_failure_at // empty' "$STATE_FILE")"
  last_alert_at="$(jq -r '.last_alert_at // empty' "$STATE_FILE")"
  last_ok_at="$(jq -r '.last_ok_at // empty' "$STATE_FILE")"
  previous_status="$(jq -r '.facade_status // .status // empty' "$STATE_FILE")"
fi

alert=false
reason=""
if [[ "$overall_status" == "ok" ]]; then
  first_failure_at=""
  last_alert_at=""
  last_ok_at="$now"
else
  [[ -n "$first_failure_at" ]] || first_failure_at="$now"
  if [[ "$previous_status" == "ok" ]]; then
    alert=true
    reason="calendar_facade_regressed"
  elif [[ -z "$last_alert_at" ]]; then
    alert=true
    reason="calendar_facade_first_failure_observed"
  else
    last_epoch="$(date -u -d "$last_alert_at" +%s 2>/dev/null || echo 0)"
    now_epoch="$(date -u -d "$now" +%s 2>/dev/null || echo 0)"
    if (( last_epoch <= 0 || (now_epoch > 0 && now_epoch - last_epoch >= REPEAT_SECONDS) )); then
      alert=true
      reason="calendar_facade_failure_repeat"
    fi
  fi
  [[ "$alert" == true ]] && last_alert_at="$now"
fi

state="$(jq -nc \
  --arg contract_version jen-calendar-facade-watch.v1 \
  --arg checked_at "$now" \
  --arg facade_status "$overall_status" \
  --arg runtime_status "$runtime_status" \
  --arg live_read_status "$live_read_status" \
  --arg posture "$posture" \
  --arg required_toolset "$REQUIRED_TOOLSET" \
  --arg telegram_platform "$TELEGRAM_PLATFORM" \
  --arg api_platform "$API_PLATFORM" \
  --arg telegram_tool_status "$telegram_tool_status" \
  --arg api_tool_status "$api_tool_status" \
  --arg first_failure_at "$first_failure_at" \
  --arg last_alert_at "$last_alert_at" \
  --arg last_ok_at "$last_ok_at" \
  --arg alert_reason "$reason" \
  --argjson alert_required "$alert" \
  --argjson health "$health" \
  '{contract_version:$contract_version,checked_at:$checked_at,status:$facade_status,facade_status:$facade_status,runtime_status:$runtime_status,live_read_status:$live_read_status,posture:$posture,required_toolset:$required_toolset,telegram_platform:$telegram_platform,api_platform:$api_platform,telegram_tool_status:$telegram_tool_status,api_tool_status:$api_tool_status,alert_required:$alert_required,health:$health}
   + (if $alert_reason == "" then {} else {alert_reason:$alert_reason} end)
   + (if $first_failure_at == "" then {} else {first_failure_at:$first_failure_at} end)
   + (if $last_alert_at == "" then {} else {last_alert_at:$last_alert_at} end)
   + (if $last_ok_at == "" then {} else {last_ok_at:$last_ok_at} end)')"
printf '%s\n' "$state" >"$STATE_FILE"

if [[ "$alert" == true ]]; then
  printf '⚠️ Jen Calendar facade degraded (%s). runtime_status=%s; live_read_status=%s; telegram_tool_status=%s; api_tool_status=%s; required_toolset=%s; checked_at=%s' \
    "$reason" "$runtime_status" "$live_read_status" "$telegram_tool_status" "$api_tool_status" "$REQUIRED_TOOLSET" "$now"
  [[ -n "$first_failure_at" ]] && printf '; first_failure_at=%s' "$first_failure_at"
  printf '. Ação sugerida: verificar tool surface/gateway da Jen antes de pedir reautenticação OAuth.\n'
fi
