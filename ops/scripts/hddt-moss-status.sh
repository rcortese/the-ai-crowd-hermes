#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${1:-} == --operation-id && $# -eq 2 ]] || { echo 'usage: hddt-moss-status.sh --operation-id ID' >&2; exit 64; }
[[ $2 =~ ^[a-z0-9][a-z0-9-]{7,63}$ ]] || exit 64
root=${HDDT_REHEARSAL:+${HDDT_STATE_ROOT:?}}; root=${root:-/mnt/user/appdata/the-ai-crowd-hddt}
op="$root/operations/$2"
[[ -d $op ]] || { echo 'operation not found' >&2; exit 66; }
[[ -f $op/terminal.json ]] && cat "$op/terminal.json" || tail -n 1 "$op/journal.log"
