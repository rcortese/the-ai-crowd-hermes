#!/usr/bin/env bash
set -euo pipefail
repo=/mnt/user/appdata/the-ai-crowd
compose=$repo/compose.yaml
container=the-ai-crowd-moss-1
candidate=sha256:adfdd874dbd08847a103464cdbdafee90e970f734b31039b3a7fcbb3ce0ef9e7
expected_old=sha256:50feac956eb7c6257846eaa0cba3640ec2b7d36f0daa5f7a02370ca69b9004e0
run_dir=$repo/ops/deploy-runs/moss-preapi-context
status=$run_dir/status.env
log=$run_dir/deploy.log
mkdir -p "$run_dir"
exec > >(tee -a "$log") 2>&1
printf 'STATE=preflight\n' >"$status"
old=$(docker inspect -f '{{.Image}}' "$container")
[ "$old" = "$expected_old" ]
[ "$(docker image inspect -f '{{.Id}}' "$candidate")" = "$candidate" ]
docker image tag "$old" the-ai-crowd/moss-all-in-one:rollback-preapi-context-50feac95
[ "$(docker image inspect -f '{{.Id}}' the-ai-crowd/moss-all-in-one:rollback-preapi-context-50feac95)" = "$old" ]
rollback(){
  printf 'STATE=rolling_back\n' >"$status"
  docker image tag "$old" the-ai-crowd/moss-all-in-one:local
  docker compose -f "$compose" up -d --no-deps --force-recreate moss
  local deadline=$((SECONDS+180)) state=''
  while [ $SECONDS -lt $deadline ]; do
    state=$(docker inspect -f '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}|{{.RestartCount}}|{{.Image}}' "$container" 2>/dev/null||true)
    [ "$state" = "running|healthy|0|$old" ]&&break
    sleep 3
  done
  if [ "$state" = "running|healthy|0|$old" ]; then printf 'STATE=rolled_back\nIMAGE=%s\n' "$old" >"$status"; else printf 'STATE=rollback_failed\nOBSERVED=%s\n' "$state" >"$status"; fi
}
cleanup_sid(){
  local sid=$1
  [ -n "$sid" ]||return 0
  printf '{"session_id":"%s"}\n' "$sid" >"$run_dir/delete.json"
  docker cp "$run_dir/delete.json" "$container:/tmp/delete.json" >/dev/null
  docker exec "$container" curl -fsS -X POST -H 'Content-Type: application/json' --data-binary @/tmp/delete.json http://127.0.0.1:8787/api/session/delete >/dev/null
  for _ in $(seq 1 15); do
    local left
    left=$(docker exec "$container" curl -fsS http://127.0.0.1:8787/api/sessions | jq --arg sid "$sid" '[.sessions[]? | select(.session_id==$sid)]|length')
    [ "$left" -eq 0 ]&&return 0
    sleep 2
  done
  return 1
}
fail(){
  local reason=$1 sid=${2:-}
  docker logs --since 15m "$container" >"$run_dir/candidate.log" 2>&1||true
  [ -z "$sid" ]||docker exec "$container" curl -fsS "http://127.0.0.1:8787/api/session?session_id=$sid" >"$run_dir/session.json"||true
  cleanup_sid "$sid"||true
  printf 'FAIL_REASON=%s\n' "$reason" >>"$status"
  rollback
  exit 1
}
# Wait for no active runs/streams for a continuous 60 seconds, max 30 minutes.
printf 'STATE=waiting_idle\n' >"$status"
deadline=$((SECONDS+1800)); idle_since=0
while [ $SECONDS -lt $deadline ]; do
  health=$(docker exec "$container" curl -fsS http://127.0.0.1:8787/health)
  active=$(printf '%s' "$health"|jq '(.active_runs//0)+(.active_streams//0)')
  if [ "$active" -eq 0 ]; then [ "$idle_since" -ne 0 ]||idle_since=$SECONDS; [ $((SECONDS-idle_since)) -ge 60 ]&&break; else idle_since=0; fi
  sleep 5
done
[ "$idle_since" -ne 0 ]&&[ $((SECONDS-idle_since)) -ge 60 ]||{ printf 'STATE=idle_timeout\n' >"$status"; exit 2; }
printf 'STATE=deploying\n' >"$status"
docker image tag "$candidate" the-ai-crowd/moss-all-in-one:local
docker compose -f "$compose" up -d --no-deps --force-recreate moss
state=''; deadline=$((SECONDS+180))
while [ $SECONDS -lt $deadline ]; do state=$(docker inspect -f '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}|{{.RestartCount}}|{{.Image}}' "$container" 2>/dev/null||true); [ "$state" = "running|healthy|0|$candidate" ]&&break; sleep 3; done
[ "$state" = "running|healthy|0|$candidate" ]||fail basic_health
[ "$(docker exec "$container" printenv HERMES_WEBUI_CHAT_BACKEND)" = legacy-direct ]||fail backend
docker exec "$container" curl -fsS http://127.0.0.1:8787/ >/dev/null||fail webui
docker exec "$container" curl -fsS http://127.0.0.1:8787/api/sessions >/dev/null||fail sessions
[ "$(docker exec "$container" sha256sum /opt/hermes-webui/static/ui.js|cut -d' ' -f1)" = 103a13a48e1729e09678a2d4c96f0282e1cfebe8b8cfd11f1b0d95705738328f ]||fail ui_checksum
docker exec "$container" sh -lc '! grep -q "DEFAULT_CTX=128\*1024" /opt/hermes-webui/static/ui.js && grep -q "hasMeasuredCtx=hasPromptTok&&hasExplicitCtx" /opt/hermes-webui/static/ui.js' ||fail context_contract
# Prepare browser dependency bundle from the existing disposable lab, never from Moss runtime state.
rm -rf "$run_dir/e2e"
docker cp roy-rollback-dev:/tmp/e2e "$run_dir/e2e" >/dev/null||fail browser_bundle
cp "$repo/ops/images/moss-preapi-context-source/moss_control_e2e.js" "$run_dir/e2e/control.js"
cp "$repo/ops/images/moss-preapi-context-source/moss_identity_e2e.js" "$run_dir/e2e/identity.js"
docker cp "$run_dir/e2e" "$container:/tmp/e2e" >/dev/null||fail browser_copy
chrome=/opt/hermes/.playwright/chromium_headless_shell-1228/chrome-headless-shell-linux64/chrome-headless-shell
set +e
control=$(timeout 180 docker exec -e CHROME="$chrome" "$container" sh -lc 'cd /tmp/e2e && node control.js' 2>&1); crc=$?
set -e
printf '%s\n' "$control" >"$run_dir/control.jsonl"
control_sid=$(printf '%s\n' "$control"|jq -rR 'fromjson?|.sid//empty'|tail -n1)
[ $crc -eq 0 ]||fail "control_rc_$crc" "$control_sid"
cleanup_sid "$control_sid"||fail control_cleanup "$control_sid"
set +e
identity=$(timeout 150 docker exec -e CHROME="$chrome" "$container" sh -lc 'cd /tmp/e2e && node identity.js' 2>&1); irc=$?
set -e
printf '%s\n' "$identity" >"$run_dir/identity.jsonl"
identity_sid=$(printf '%s\n' "$identity"|jq -rR 'fromjson?|.sid//empty'|tail -n1)
[ $irc -eq 0 ]||fail "identity_rc_$irc" "$identity_sid"
cleanup_sid "$identity_sid"||fail identity_cleanup "$identity_sid"
final=$(docker inspect -f '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}|{{.RestartCount}}|{{.Image}}' "$container")
[ "$final" = "running|healthy|0|$candidate" ]||fail final_health
printf 'STATE=success\nIMAGE=%s\nCONTROL_SID_CLEANED=%s\nIDENTITY_SID_CLEANED=%s\n' "$candidate" "$control_sid" "$identity_sid" >"$status"
echo "MOSS_PREAPI_CONTEXT_DEPLOY=SUCCESS $final"
