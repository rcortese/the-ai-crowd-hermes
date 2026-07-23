#!/usr/bin/env bash
# Read-only HDDT reconciliation.
set -Eeuo pipefail
[[ ${1:-} == --operation-id && $# == 2 && $2 =~ ^[a-z0-9][a-z0-9-]{7,63}$ ]]||exit 64
root=$([[ ${HDDT_REHEARSAL:-0} == 1 ]]&&printf %s "${HDDT_STATE_ROOT:?}"||printf %s /mnt/ssd/appdata/the-ai-crowd-hddt); op="$root/operations/$2"; [[ -d $op ]]||exit 66
last=$(awk -F '\t' 'END{print $2}' "$op/journal.log"); runner_state=$( [[ -f $op/runner.started.json ]] && printf started || ([[ -f $op/runner.exit.json ]] && printf exited || printf absent) ); legacy=false
[[ $(jq -e 'has("builder_sha256") and has("launcher_sha256") and .mode=="followable"' "$op/request.json" >/dev/null 2>&1; printf %s $?) == 0 ]] || legacy=true
terminal_state=$(jq -r '.state//""' "$op/terminal.json" 2>/dev/null||true); live=$("${HDDT_DOCKER_BIN:-/usr/bin/docker}" inspect the-ai-crowd-moss-1 2>/dev/null||printf '{}')
candidate=$(jq -r .candidate_image_id "$op/request.json"); rollback=$(jq -r .rollback_image_id "$op/request.json"); image=$(jq -r '.Image//"unavailable"' <<<"$live"); divergence=false
case $terminal_state in SUCCEEDED) [[ $image == "$candidate" ]]||divergence=true;; ROLLED_BACK) [[ $image == "$rollback" ]]||divergence=true;; esac
jq -nc --arg op "$2" --arg last "$last" --arg terminal "$terminal_state" --arg image "$image" --argjson divergence "$divergence" --argjson running "$(jq '.State.Running//false' <<<"$live")" --arg health "$(jq -r '.State.Health.Status//"unavailable"' <<<"$live")" --arg id "$(jq -r '.Id//"unavailable"' <<<"$live")" --arg started "$(jq -r '.State.StartedAt//"unavailable"' <<<"$live")" --argjson restarts "$(jq '.RestartCount//-1' <<<"$live")" --arg runner_state "$runner_state" --argjson legacy_schema "$legacy" '{operation_id:$op,last_state:$last,terminal_state:$terminal,runner_state:$runner_state,legacy_schema:$legacy_schema,divergence:$divergence,live:{container_id:$id,image_id:$image,running:$running,health:$health,started_at:$started,restart_count:$restarts}}'
