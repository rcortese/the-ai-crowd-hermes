#!/usr/bin/env bash
set -euo pipefail
STATE_DIR="${JEN_CRON_STATE_DIR:-/opt/data/state/jen-cron}"
STATE_FILE="$STATE_DIR/calendar-auth-watch.json"
REPEAT_SECONDS="${JEN_CALENDAR_AUTH_WATCH_REPEAT_SECONDS:-21600}"
mkdir -p "$STATE_DIR"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
health_file="$(mktemp)"
trap 'rm -f "$health_file"' EXIT
if ! /agents/jen/public/tools/wrappers/jen-calendar-runtime health >"$health_file" 2>/dev/null || ! jq empty "$health_file" >/dev/null 2>&1; then
  health="$(jq -nc --arg checked_at "$now" '{status:"degraded",live_read_status:"runtime_failure",checked_at:$checked_at}')"
else
  health="$(jq -c . "$health_file")"
fi
runtime_status="$(jq -r '.status // "degraded"' <<<"$health")"
live_read_status="$(jq -r '.live_read_status // "unknown"' <<<"$health")"
posture="$(jq -r '.posture // "unknown"' <<<"$health")"
alert=false
reason=""
first_failure_at=""
last_alert_at=""
last_ok_at=""
if [[ -f "$STATE_FILE" ]] && jq empty "$STATE_FILE" >/dev/null 2>&1; then
  first_failure_at="$(jq -r '.first_failure_at // empty' "$STATE_FILE")"
  last_alert_at="$(jq -r '.last_alert_at // empty' "$STATE_FILE")"
  last_ok_at="$(jq -r '.last_ok_at // empty' "$STATE_FILE")"
  previous_runtime_status="$(jq -r '.runtime_status // empty' "$STATE_FILE")"
  previous_live_read_status="$(jq -r '.live_read_status // empty' "$STATE_FILE")"
else
  previous_runtime_status=""
  previous_live_read_status=""
fi
if [[ "$runtime_status" == "ok" && "$live_read_status" == "ok" ]]; then
  first_failure_at=""
  last_ok_at="$now"
  last_alert_at=""
else
  [[ -n "$first_failure_at" ]] || first_failure_at="$now"
  if [[ "$previous_runtime_status" == "ok" && "$previous_live_read_status" == "ok" ]]; then
    alert=true; reason="calendar_health_regressed"
  elif [[ -z "$last_alert_at" ]]; then
    alert=true; reason="calendar_health_first_failure_observed"
  else
    last_epoch="$(date -u -d "$last_alert_at" +%s 2>/dev/null || echo 0)"
    now_epoch="$(date -u -d "$now" +%s 2>/dev/null || echo 0)"
    if (( last_epoch <= 0 || (now_epoch > 0 && now_epoch - last_epoch >= REPEAT_SECONDS) )); then
      alert=true; reason="calendar_health_failure_repeat"
    fi
  fi
  [[ "$alert" == true ]] && last_alert_at="$now"
fi
state="$(jq -nc \
  --arg contract_version jen-calendar-auth-watch.v1 \
  --arg checked_at "$now" \
  --arg runtime_status "$runtime_status" \
  --arg live_read_status "$live_read_status" \
  --arg posture "$posture" \
  --arg first_failure_at "$first_failure_at" \
  --arg last_alert_at "$last_alert_at" \
  --arg last_ok_at "$last_ok_at" \
  --arg alert_reason "$reason" \
  --argjson alert_required "$alert" \
  --argjson health "$health" \
  '{contract_version:$contract_version,checked_at:$checked_at,status:"ok",runtime_status:$runtime_status,live_read_status:$live_read_status,posture:$posture,alert_required:$alert_required,health:$health}
   + (if $alert_reason == "" then {} else {alert_reason:$alert_reason} end)
   + (if $first_failure_at == "" then {} else {first_failure_at:$first_failure_at} end)
   + (if $last_alert_at == "" then {} else {last_alert_at:$last_alert_at} end)
   + (if $last_ok_at == "" then {} else {last_ok_at:$last_ok_at} end)')"
printf '%s\n' "$state" >"$STATE_FILE"
if [[ "$alert" == true ]]; then
  if [[ "$live_read_status" == "auth_failure" ]]; then
    action='A ação provável é refazer o consentimento OAuth do Google para a conta da Jen.'
  else
    action='Ação sugerida: verificar o runtime do Calendar da Jen e o provedor Google/gog.'
  fi
  printf '⚠️ Jen Calendar: runtime degradado (%s). runtime_status=%s; live_read_status=%s; checked_at=%s' "$reason" "$runtime_status" "$live_read_status" "$now"
  [[ -n "$first_failure_at" ]] && printf '; first_failure_at=%s' "$first_failure_at"
  printf '. %s\n' "$action"
fi
