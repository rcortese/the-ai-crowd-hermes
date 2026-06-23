#!/usr/bin/env bash
set -euo pipefail

jen_json_out() {
  printf '%s\n' "$1"
}

jen_now_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

jen_new_handoff_id() {
  local boundary="${1:-jen-wrapper}"
  printf 'moss:%s:%s:%s\n' "$boundary" "$(date -u +%Y%m%dT%H%M%SZ)" "${RANDOM:-0}"
}

jen_emit_envelope() {
  local contract_version="$1"
  local status="$2"
  local result="$3"
  local failure_class="$4"
  local jen_action="$5"
  local operator_message="$6"
  local handoff_id="${7:-}"
  local detail_json="${8:-null}"
  local extra_json='{}'
  if [[ $# -ge 9 ]]; then
    extra_json="$9"
  fi

  jq -nc \
    --arg contract_version "$contract_version" \
    --arg status "$status" \
    --arg result "$result" \
    --arg failure_class "$failure_class" \
    --arg jen_action "$jen_action" \
    --arg operator_message "$operator_message" \
    --arg handoff_id "$handoff_id" \
    --argjson detail "$detail_json" \
    --argjson extra "$extra_json" \
    '{
      contract_version:$contract_version,
      status:$status,
      result:$result,
      failure_class:$failure_class,
      jen_action:$jen_action,
      operator_message:$operator_message,
      handoff_id:(if $handoff_id != "" then $handoff_id else null end),
      detail:(if $detail == null then null else $detail end)
    } + $extra'
}
