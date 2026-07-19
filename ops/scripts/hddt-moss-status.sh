#!/usr/bin/env bash
# Read-only reconciliation: no lock, no rename, no lifecycle invocation.
set -Eeuo pipefail
[[ ${1:-} == --operation-id && $# == 2 && $2 =~ ^[a-z0-9][a-z0-9-]{7,63}$ ]] || { printf '%s\n' 'usage: hddt-moss-status.sh --operation-id ID' >&2; exit 64; }
root=${HDDT_REHEARSAL:+${HDDT_STATE_ROOT:?}}; root=${root:-/mnt/user/appdata/the-ai-crowd-hddt}
op="$root/operations/$2"
[[ -d $op ]] || { printf '%s\n' 'operation not found' >&2; exit 66; }
terminal=${op}/terminal.json
last=$(awk 'END{print $2}' "$op/journal.log" 2>/dev/null || true)
live=unavailable
if [[ ${HDDT_REHEARSAL:-0} == 1 && -n ${HDDT_DOCKER_BIN:-} ]]; then
  live=$("$HDDT_DOCKER_BIN" inspect the-ai-crowd-moss-1 2>/dev/null || printf '%s' unavailable)
fi
state=$(sed -n 's/.*"state":"\([^"]*\)".*/\1/p' "$terminal" 2>/dev/null || true)
divergence=false
if [[ -n $state && $live != unavailable && -f $op/snapshot.env ]]; then
  candidate=$(sed -n 's/^candidate_image_id=//p' "$op/snapshot.env")
  rollback=$(sed -n 's/^rollback_image_id=//p' "$op/snapshot.env")
  case $state in SUCCEEDED) [[ $live == *"$candidate"* ]] || divergence=true;; ROLLED_BACK) [[ $live == *"$rollback"* ]] || divergence=true;; esac
fi
printf '{"operation_id":"%s","last_state":"%s","terminal_state":"%s","divergence":%s,"live":%s}\n' "$2" "${last:-UNKNOWN}" "${state:-}" "$divergence" "$(printf '%s' "$live" | tr -d '\n')"
