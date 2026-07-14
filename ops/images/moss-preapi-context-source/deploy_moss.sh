#!/usr/bin/env bash
set -euo pipefail
repo=/mnt/user/appdata/the-ai-crowd
source_compose=$repo/compose.yaml
source_override=$repo/runtime/moss-home/backups/profile-migration-stage-20260713T205512Z/rollback.override.yaml
container=the-ai-crowd-moss-1
candidate=sha256:69ee98d54f088fae99dae70f483eb515fcfdccc7dc1a91de86847d4edb6b1e9b
expected_old=sha256:adfdd874dbd08847a103464cdbdafee90e970f734b31039b3a7fcbb3ce0ef9e7
production_tag=the-ai-crowd-moss:profile-rollback-20260713T205512Z
run_parent=$repo/ops/deploy-runs/moss-preapi-context
run_id=$(date -u +%Y%m%dT%H%M%SZ)-$$
run_dir=$run_parent/$run_id
browser_bundle=$repo/ops/runtime-assets/playwright-core-1.57.0
expected_browser_bundle_sha=38a6c949f11c2c8233976d046d870ca465e02c12663d381d602ed8eb2fb2e133
expected_control_sha=2aff1f8b2acadf3b39b7c24d0d1e69b3860d11bfa1f4a667297e76af9e9dcf45
expected_identity_sha=73399b897b575363d79e001336be81fe978c9ebf8a7f25dac130c1ad3777c48d
expected_cancel_visual_sha=7db5e7db88c0fcf2b44ec786acb36743b6a50be29d22b37b82fd806e20a6d638
expected_source_compose_sha=df9ade62d056b8b30bb9a93e2efc0d6bff14c6c506f270f721229595eef6b16c
expected_source_override_sha=181f8f0bdf25e26356b0a7c46a85589d90d5c7bb11e7f3ecf20d53fb3e790999
expected_supervisor_sha=75fd10ca6567379dbca652cd01cf3f92529a06fda1dbe3bb84d2a861d129f2d4
expected_fenced_supervisor_sha=eed0efb7f0e6ccde7b394a001ce04e9e538d558557f2a14de2686c04cceaf0d3
status=$run_dir/status.env
log=$run_dir/deploy.log
mkdir -p "$run_parent"
mkdir "$run_dir"
exec > >(tee -a "$log") 2>&1
printf '%s\n' "$run_dir" >"$run_parent/latest_run"
printf 'STATE=preflight\n' >"$status"
mutation_started=0
probe=''
preflight_cleanup(){ [ -z "$probe" ]||docker rm -f "$probe" >/dev/null 2>&1||true; }
trap preflight_cleanup EXIT
# Freeze every mutable input that will be consumed after the admission fence.
compose_snapshot=$run_dir/compose.yaml
override_snapshot=$run_dir/override.yaml
e2e_dir=$run_dir/e2e
container_e2e=/tmp/e2e-$run_id
supervisor_original=$run_dir/moss-all-in-one.conf.original
supervisor_fenced=$run_dir/moss-all-in-one.conf.fenced
[ "$(sha256sum "$source_compose" | cut -d' ' -f1)" = "$expected_source_compose_sha" ]
[ "$(sha256sum "$source_override" | cut -d' ' -f1)" = "$expected_source_override_sha" ]
cp "$source_compose" "$compose_snapshot"
cp "$source_override" "$override_snapshot"
[ "$(sha256sum "$compose_snapshot" | cut -d' ' -f1)" = "$expected_source_compose_sha" ]
[ "$(sha256sum "$override_snapshot" | cut -d' ' -f1)" = "$expected_source_override_sha" ]
mkdir -p "$e2e_dir"
cp -a "$browser_bundle/node_modules" "$browser_bundle/package.json" "$browser_bundle/package-lock.json" "$e2e_dir/"
cp "$repo/ops/images/moss-preapi-context-source/moss_control_e2e.js" "$e2e_dir/control.js"
cp "$repo/ops/images/moss-preapi-context-source/moss_identity_e2e.js" "$e2e_dir/identity.js"
cp "$repo/ops/images/moss-preapi-context-source/moss_cancel_visual_e2e.js" "$e2e_dir/cancel-visual.js"
probe=$(docker create "$candidate")
docker cp "$probe:/etc/supervisor/conf.d/moss-all-in-one.conf" "$supervisor_original"
docker rm "$probe" >/dev/null
probe=''
[ "$(sha256sum "$supervisor_original" | cut -d' ' -f1)" = "$expected_supervisor_sha" ]
python3 - "$supervisor_original" "$supervisor_fenced" <<'PYFENCE'
from pathlib import Path
import sys
source, destination = map(Path, sys.argv[1:])
text = source.read_text()
start = text.index("[program:moss-gateway]")
end = text.find(chr(10) + "[", start)
end = len(text) if end < 0 else end + 1
block = text[start:end]
if block.count("autostart=true") != 1:
    raise SystemExit("unexpected moss-gateway autostart anchor")
destination.write_text(text[:start] + block.replace("autostart=true", "autostart=false") + text[end:])
PYFENCE
[ "$(sha256sum "$supervisor_fenced" | cut -d' ' -f1)" = "$expected_fenced_supervisor_sha" ]
chmod -R a-w "$compose_snapshot" "$override_snapshot" "$e2e_dir" "$supervisor_original" "$supervisor_fenced"
compose_sha=$(sha256sum "$compose_snapshot" | cut -d' ' -f1)
override_sha=$(sha256sum "$override_snapshot" | cut -d' ' -f1)
compose_args=(--project-directory "$repo" -f "$compose_snapshot" -f "$override_snapshot")
verify_compose_snapshot(){
  [ "$(sha256sum "$compose_snapshot" | cut -d' ' -f1)" = "$compose_sha" ] &&
  [ "$(sha256sum "$override_snapshot" | cut -d' ' -f1)" = "$override_sha" ] &&
  [ "$(docker compose "${compose_args[@]}" config --format json | jq -r '.services.moss.image')" = "$production_tag" ]
}
verify_e2e_snapshot(){
  [ "$(jq -r '.dependencies."playwright-core"' "$e2e_dir/package.json")" = "1.57.0" ] &&
  [ "$(jq -r '.version' "$e2e_dir/node_modules/playwright-core/package.json")" = "1.57.0" ] &&
  [ "$(tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner --mode=a-w -C "$e2e_dir" -cf - package.json package-lock.json node_modules | sha256sum | cut -d' ' -f1)" = "$expected_browser_bundle_sha" ] &&
  [ "$(sha256sum "$e2e_dir/control.js" | cut -d' ' -f1)" = "$expected_control_sha" ] &&
  [ "$(sha256sum "$e2e_dir/identity.js" | cut -d' ' -f1)" = "$expected_identity_sha" ] &&
  [ "$(sha256sum "$e2e_dir/cancel-visual.js" | cut -d' ' -f1)" = "$expected_cancel_visual_sha" ]
}
verify_container_e2e(){
  [ "$(docker exec "$container" sha256sum "$container_e2e/control.js" | cut -d' ' -f1)" = "$expected_control_sha" ] &&
  [ "$(docker exec "$container" sha256sum "$container_e2e/identity.js" | cut -d' ' -f1)" = "$expected_identity_sha" ] &&
  [ "$(docker exec "$container" sha256sum "$container_e2e/cancel-visual.js" | cut -d' ' -f1)" = "$expected_cancel_visual_sha" ] &&
  [ "$(docker exec "$container" node -p "require('$container_e2e/node_modules/playwright-core/package.json').version")" = "1.57.0" ] &&
  [ "$(docker exec "$container" tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner --mode=a-w -C "$container_e2e" -cf - package.json package-lock.json node_modules | sha256sum | cut -d' ' -f1)" = "$expected_browser_bundle_sha" ]
}
verify_compose_snapshot
verify_e2e_snapshot
old=$(docker inspect -f '{{.Image}}' "$container")
[ "$old" = "$expected_old" ]
[ "$(docker image inspect -f '{{.Id}}' "$candidate")" = "$candidate" ]
docker image tag "$old" the-ai-crowd/moss-all-in-one:rollback-cancel-flicker-adfdd874
[ "$(docker image inspect -f '{{.Id}}' the-ai-crowd/moss-all-in-one:rollback-cancel-flicker-adfdd874)" = "$old" ]
rollback(){
  printf 'STATE=rolling_back\n' >"$status"
  verify_compose_snapshot || { printf 'STATE=rollback_failed\nOBSERVED=compose_snapshot_drift\n' >"$status"; return 1; }
  docker image tag "$old" "$production_tag"
  docker compose "${compose_args[@]}" up -d --no-deps --force-recreate moss
  local deadline=$((SECONDS+180)) state=''
  while [ $SECONDS -lt $deadline ]; do
    state=$(docker inspect -f '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}|{{.RestartCount}}|{{.Image}}' "$container" 2>/dev/null||true)
    [ "$state" = "running|healthy|0|$old" ]&&break
    sleep 3
  done
  if [ "$state" = "running|healthy|0|$old" ]; then printf 'STATE=rolled_back\nIMAGE=%s\n' "$old" >"$status"; else printf 'STATE=rollback_failed\nOBSERVED=%s\n' "$state" >"$status"; fi
}
on_exit(){
  local rc=$?
  trap - EXIT
  if [ "$rc" -ne 0 ] && [ "$mutation_started" -eq 1 ]; then
    rollback || true
  fi
  exit "$rc"
}
trap on_exit EXIT
cleanup_sid(){
  local sid=$1 consecutive_absent=0 left
  [ -n "$sid" ]||return 0
  printf '{"session_id":"%s"}\n' "$sid" >"$run_dir/delete.json"
  docker cp "$run_dir/delete.json" "$container:/tmp/delete.json" >/dev/null
  docker exec "$container" curl -fsS -X POST -H 'Content-Type: application/json' --data-binary @/tmp/delete.json http://127.0.0.1:8787/api/session/delete >/dev/null
  # A completed browser may flush a final session write after the delete ACK.
  # Require five consecutive absent samples and re-delete any late reappearance.
  for _ in $(seq 1 30); do
    left=$(docker exec "$container" curl -fsS http://127.0.0.1:8787/api/sessions | jq --arg sid "$sid" '[.sessions[]? | select(.session_id==$sid)]|length')
    if [ "$left" -eq 0 ]; then
      consecutive_absent=$((consecutive_absent+1))
      [ "$consecutive_absent" -ge 5 ]&&return 0
    else
      consecutive_absent=0
      docker exec "$container" curl -fsS -X POST -H 'Content-Type: application/json' --data-binary @/tmp/delete.json http://127.0.0.1:8787/api/session/delete >/dev/null
    fi
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
# Establish admission fence before the authoritative zero-work assertion:
# stop platform ingress and disconnect only Caddy's ingress network. Internal
# egress stays connected so an already-admitted WebUI run can finish draining.
mutation_started=1
docker exec "$container" supervisorctl -c /etc/supervisor/conf.d/moss-all-in-one.conf stop moss-gateway
docker network disconnect network_default "$container"
printf 'STATE=fenced_draining\n' >"$status"
fence_deadline=$((SECONDS+300)); fenced_idle_since=0
while [ $SECONDS -lt $fence_deadline ]; do
  fenced_health=$(docker exec "$container" curl -fsS http://127.0.0.1:8787/health)
  fenced_active=$(printf '%s' "$fenced_health"|jq '(.active_runs//0)+(.active_streams//0)')
  if [ "$fenced_active" -eq 0 ]; then [ "$fenced_idle_since" -ne 0 ]||fenced_idle_since=$SECONDS; [ $((SECONDS-fenced_idle_since)) -ge 10 ]&&break; else fenced_idle_since=0; fi
  sleep 2
done
[ "$fenced_idle_since" -ne 0 ]&&[ $((SECONDS-fenced_idle_since)) -ge 10 ]||fail fenced_drain_timeout
docker stop --time 30 "$container" >/dev/null
printf 'STATE=deploying\n' >"$status"
verify_compose_snapshot || fail compose_snapshot_drift
docker image tag "$candidate" "$production_tag"
docker compose "${compose_args[@]}" up --no-deps --force-recreate --no-start moss
[ "$(docker inspect -f '{{.Image}}' "$container")" = "$candidate" ]||fail candidate_created_image
[ "$(docker inspect -f '{{.State.Status}}' "$container")" = created ]||fail candidate_started_before_fence
docker cp "$supervisor_fenced" "$container:/etc/supervisor/conf.d/moss-all-in-one.conf"||fail candidate_fence_config
[ "$(docker cp "$container:/etc/supervisor/conf.d/moss-all-in-one.conf" - | tar -xO | sha256sum | cut -d' ' -f1)" = "$expected_fenced_supervisor_sha" ]||fail candidate_fence_config_readback
docker network disconnect network_default "$container"||fail candidate_ingress_fence
docker start "$container" >/dev/null||fail candidate_start
state=''; deadline=$((SECONDS+180))
while [ $SECONDS -lt $deadline ]; do state=$(docker inspect -f '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}|{{.RestartCount}}|{{.Image}}' "$container" 2>/dev/null||true); [ "$state" = "running|healthy|0|$candidate" ]&&break; sleep 3; done
[ "$state" = "running|healthy|0|$candidate" ]||fail basic_health
for _ in $(seq 1 30); do gateway_state=$(docker exec "$container" supervisorctl -c /etc/supervisor/conf.d/moss-all-in-one.conf status moss-gateway 2>/dev/null||true); [[ "$gateway_state" == *STOPPED* ]]&&break; sleep 1; done
[[ "$gateway_state" == *STOPPED* ]]||fail candidate_gateway_fence
[ "$(docker inspect -f '{{json .NetworkSettings.Networks}}' "$container" | jq 'has("network_default")')" = false ]||fail candidate_ingress_fence
[ "$(docker exec "$container" printenv HERMES_WEBUI_CHAT_BACKEND)" = legacy-direct ]||fail backend
docker exec "$container" curl -fsS http://127.0.0.1:8787/ >/dev/null||fail webui
docker exec "$container" curl -fsS http://127.0.0.1:8787/api/sessions >/dev/null||fail sessions
[ "$(docker exec "$container" sha256sum /opt/hermes-webui/static/ui.js|cut -d' ' -f1)" = 103a13a48e1729e09678a2d4c96f0282e1cfebe8b8cfd11f1b0d95705738328f ]||fail ui_checksum
docker exec "$container" sh -lc '! grep -q "DEFAULT_CTX=128\*1024" /opt/hermes-webui/static/ui.js && grep -q "hasMeasuredCtx=hasPromptTok&&hasExplicitCtx" /opt/hermes-webui/static/ui.js' ||fail context_contract
# Consume only the read-only, hash-bound E2E snapshot prepared before fencing.
verify_e2e_snapshot ||fail browser_bundle_snapshot_drift
docker exec "$container" mkdir "$container_e2e" ||fail browser_destination
docker cp "$e2e_dir/." "$container:$container_e2e/" >/dev/null||fail browser_copy
verify_e2e_snapshot ||fail browser_bundle_snapshot_drift
verify_container_e2e ||fail browser_copy_verification
chrome=/opt/hermes/.playwright/chromium_headless_shell-1228/chrome-headless-shell-linux64/chrome-headless-shell
set +e
control=$(timeout 180 docker exec -e CHROME="$chrome" "$container" sh -lc "cd '$container_e2e' && node control.js" 2>&1); crc=$?
set -e
printf '%s\n' "$control" >"$run_dir/control.jsonl"
control_sid=$(printf '%s\n' "$control"|jq -rR 'fromjson? | .sid // empty'|head -n1)
[ $crc -eq 0 ]||fail "control_rc_$crc" "$control_sid"
cleanup_sid "$control_sid"||fail control_cleanup "$control_sid"
verify_e2e_snapshot ||fail browser_bundle_snapshot_drift
verify_container_e2e ||fail browser_copy_verification
set +e
cancel_visual=$(timeout 120 docker exec -e CHROME="$chrome" -e OUT="$container_e2e/cancel-trace.json" "$container" sh -lc "cd '$container_e2e' && node cancel-visual.js" 2>&1); vrc=$?
set -e
printf '%s
' "$cancel_visual" >"$run_dir/cancel-visual.jsonl"
cancel_sid=$(printf '%s
' "$cancel_visual"|jq -rR 'fromjson? | .sid // empty'|head -n1)
[ $vrc -eq 0 ]||fail "cancel_visual_rc_$vrc" "$cancel_sid"
docker cp "$container:$container_e2e/cancel-trace.json" "$run_dir/cancel-trace.json" >/dev/null||fail cancel_visual_evidence "$cancel_sid"
[ -s "$run_dir/cancel-trace.json" ]||fail cancel_visual_evidence "$cancel_sid"
cleanup_sid "$cancel_sid"||fail cancel_visual_cleanup "$cancel_sid"
verify_e2e_snapshot ||fail browser_bundle_snapshot_drift
verify_container_e2e ||fail browser_copy_verification
set +e
identity=$(timeout 150 docker exec -e CHROME="$chrome" "$container" sh -lc "cd '$container_e2e' && node identity.js" 2>&1); irc=$?
set -e
printf '%s\n' "$identity" >"$run_dir/identity.jsonl"
identity_sid=$(printf '%s\n' "$identity"|jq -rR 'fromjson? | .sid // empty'|head -n1)
[ $irc -eq 0 ]||fail "identity_rc_$irc" "$identity_sid"
cleanup_sid "$identity_sid"||fail identity_cleanup "$identity_sid"
docker cp "$supervisor_original" "$container:/etc/supervisor/conf.d/moss-all-in-one.conf"||fail gateway_config_restore
[ "$(docker cp "$container:/etc/supervisor/conf.d/moss-all-in-one.conf" - | tar -xO | sha256sum | cut -d' ' -f1)" = "$expected_supervisor_sha" ]||fail gateway_config_restore_readback
docker exec "$container" supervisorctl -c /etc/supervisor/conf.d/moss-all-in-one.conf reread >/dev/null||fail gateway_reread
docker exec "$container" supervisorctl -c /etc/supervisor/conf.d/moss-all-in-one.conf update >/dev/null||fail gateway_update
docker exec "$container" supervisorctl -c /etc/supervisor/conf.d/moss-all-in-one.conf start moss-gateway >/dev/null||fail gateway_start
for _ in $(seq 1 30); do gateway_state=$(docker exec "$container" supervisorctl -c /etc/supervisor/conf.d/moss-all-in-one.conf status moss-gateway 2>/dev/null||true); [[ "$gateway_state" == *RUNNING* ]]&&break; sleep 1; done
[[ "$gateway_state" == *RUNNING* ]]||fail gateway_running
docker network connect --alias moss --alias hermes network_default "$container"||fail ingress_restore
[ "$(docker inspect -f '{{json (index .NetworkSettings.Networks "network_default").Aliases}}' "$container" | jq -c 'sort')" = '["hermes","moss","the-ai-crowd-moss-1"]' ]||fail ingress_aliases
docker exec network-caddy-1 curl -fsS http://moss:8787/ >/dev/null||fail ingress_route
final=$(docker inspect -f '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}|{{.RestartCount}}|{{.Image}}' "$container")
[ "$final" = "running|healthy|0|$candidate" ]||fail final_health
printf 'STATE=success\nIMAGE=%s\nCONTROL_SID_CLEANED=%s\nCANCEL_VISUAL_SID_CLEANED=%s\nIDENTITY_SID_CLEANED=%s\n' "$candidate" "$control_sid" "$cancel_sid" "$identity_sid" >"$status"
mutation_started=0
echo "MOSS_PREAPI_CONTEXT_DEPLOY=SUCCESS $final"
