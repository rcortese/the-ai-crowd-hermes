#!/usr/bin/env bash
set -euo pipefail
STATE_DIR="${JEN_CRON_STATE_DIR:-/opt/data/state/jen-cron}"
STATE_FILE="$STATE_DIR/calendar-auth-watch.json"
REPEAT_SECONDS="${JEN_CALENDAR_AUTH_WATCH_REPEAT_SECONDS:-21600}"
CALENDAR_RUNTIME_WRAPPER="${JEN_CALENDAR_RUNTIME_WRAPPER:-/agents/jen/public/tools/wrappers/jen-calendar-runtime}"
HANDOFF_WRAPPER="${JEN_HANDOFF_WRAPPER:-/agents/jen/public/bin/jen-handoff}"
HANDOFF_MODE="${JEN_CALENDAR_AUTH_WATCH_HANDOFF_MODE:-off}"
HANDOFF_ROOT="${JEN_CALENDAR_AUTH_WATCH_HANDOFF_ROOT:-/mnt/hermes-shared/handoffs}"
HANDOFF_ALLOW_TEST_ROOT="${JEN_CALENDAR_AUTH_WATCH_ALLOW_TEST_ROOT:-0}"
mkdir -p "$STATE_DIR"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
health_file="$(mktemp)"
handoff_file="$(mktemp)"
trap 'rm -f "$health_file" "$handoff_file"' EXIT
if ! "$CALENDAR_RUNTIME_WRAPPER" health >"$health_file" 2>/dev/null || ! jq empty "$health_file" >/dev/null 2>&1; then
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
handoff_json='null'
handoff_error=''
handoff_failure_class=''
if [[ "$alert" == true && "$HANDOFF_MODE" != "off" ]]; then
  if [[ "$live_read_status" == "auth_failure" ]]; then
    handoff_failure_class='auth_failure'
    action='A ação provável é refazer o consentimento OAuth do Google para a conta da Jen.'
  else
    handoff_failure_class='runtime_failure'
    action='Ação sugerida: verificar o runtime do Calendar da Jen e o provedor Google/gog.'
  fi
  handoff_context="Jen Calendar technical degradation detected.\nalert_reason: $reason\nruntime_status: $runtime_status\nlive_read_status: $live_read_status\nposture: $posture\nchecked_at: $now"
  [[ -n "$first_failure_at" ]] && handoff_context+="\nfirst_failure_at: $first_failure_at"
  handoff_cmd=(
    "$HANDOFF_WRAPPER" emit
    --target moss
    --owner-domain technical-ops
    --handoff-type incident
    --failure-class "$handoff_failure_class"
    --summary "Jen Calendar degraded: ${reason}"
    --objective "Create a sanitized technical incident for Moss triage without exposing OAuth materials."
    --context "$handoff_context"
    --idempotency-key "jen-calendar-auth-watch:${reason}:${live_read_status}:${first_failure_at:-$now}"
    --root "$HANDOFF_ROOT"
  )
  [[ "$HANDOFF_ALLOW_TEST_ROOT" == "1" ]] && handoff_cmd+=(--allow-test-root)
  if [[ "$HANDOFF_MODE" == "write" || "$HANDOFF_MODE" == "emit" ]]; then
    handoff_cmd+=(--write)
  else
    handoff_cmd+=(--dry-run)
  fi
  if "${handoff_cmd[@]}" >"$handoff_file" 2>&1; then
    handoff_json="$(jq -c . "$handoff_file")"
  else
    handoff_error="$(cat "$handoff_file")"
  fi
else
  if [[ "$live_read_status" == "auth_failure" ]]; then
    action='A ação provável é refazer o consentimento OAuth do Google para a conta da Jen.'
  else
    action='Ação sugerida: verificar o runtime do Calendar da Jen e o provedor Google/gog.'
  fi
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
  --arg handoff_mode "$HANDOFF_MODE" \
  --arg handoff_wrapper "$HANDOFF_WRAPPER" \
  --arg handoff_root "$HANDOFF_ROOT" \
  --arg handoff_error "$handoff_error" \
  --arg handoff_failure_class "$handoff_failure_class" \
  --argjson alert_required "$alert" \
  --argjson health "$health" \
  --argjson canonical_handoff "$handoff_json" \
  '{contract_version:$contract_version,checked_at:$checked_at,status:"ok",runtime_status:$runtime_status,live_read_status:$live_read_status,posture:$posture,alert_required:$alert_required,health:$health}
   + (if $alert_reason == "" then {} else {alert_reason:$alert_reason} end)
   + (if $first_failure_at == "" then {} else {first_failure_at:$first_failure_at} end)
   + (if $last_alert_at == "" then {} else {last_alert_at:$last_alert_at} end)
   + (if $last_ok_at == "" then {} else {last_ok_at:$last_ok_at} end)
   + (if $handoff_mode == "off" then {} else {canonical_handoff_mode:$handoff_mode,canonical_handoff_wrapper:$handoff_wrapper,canonical_handoff_root:$handoff_root} end)
   + (if $handoff_failure_class == "" then {} else {canonical_handoff_failure_class:$handoff_failure_class} end)
   + (if $canonical_handoff == null then {} else {canonical_handoff:$canonical_handoff} end)
   + (if $handoff_error == "" then {} else {canonical_handoff_error:$handoff_error} end)')"
printf '%s\n' "$state" >"$STATE_FILE"
if [[ "$alert" == true ]]; then
  printf '⚠️ Jen Calendar: runtime degradado (%s). runtime_status=%s; live_read_status=%s; checked_at=%s' "$reason" "$runtime_status" "$live_read_status" "$now"
  [[ -n "$first_failure_at" ]] && printf '; first_failure_at=%s' "$first_failure_at"
  if [[ "$HANDOFF_MODE" != "off" && -z "$handoff_error" ]]; then
    printf '; canonical_handoff_mode=%s' "$HANDOFF_MODE"
  elif [[ -n "$handoff_error" ]]; then
    printf '; canonical_handoff_error=1'
  fi
  printf '. %s\n' "$action"
fi
if [[ "$alert" == true && -n "$handoff_error" ]]; then
  printf '%s\n' "$handoff_error" >&2
  exit 1
fi
