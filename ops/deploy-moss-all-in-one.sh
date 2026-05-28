#!/usr/bin/env bash
set -euo pipefail

# Host-side Moss all-in-one deploy guardrail.
# Run from Unraid/media host, not from inside the Moss container.
# This script treats Docker state "created" as a failed/interrupted start and
# recovers once with a scoped compose up/start before declaring success.

STACK_DIR="${STACK_DIR:-/mnt/user/appdata/the-ai-crowd}"
SERVICE="${SERVICE:-moss}"
CONTAINER="${CONTAINER:-the-ai-crowd-moss-1}"
IMAGE="${IMAGE:-the-ai-crowd/moss-all-in-one:local}"
LOG_PREFIX="[deploy-moss]"

cd "$STACK_DIR"

log() { printf '%s %s\n' "$LOG_PREFIX" "$*"; }
state() { docker inspect "$CONTAINER" --format '{{.State.Status}}' 2>/dev/null || true; }
image_id() { docker image inspect "$IMAGE" --format '{{.Id}}'; }

log "rendering compose model"
docker compose config --quiet

log "building $SERVICE image"
DOCKER_BUILDKIT=1 docker compose build "$SERVICE"
NEW_IMAGE_ID="$(image_id)"
log "built $IMAGE as $NEW_IMAGE_ID"

log "preflight image contents"
docker run --rm --entrypoint sh "$IMAGE" -lc '
  set -e
  cd /opt/hermes
  git rev-parse HEAD
  test ! -e /tmp/kanban-dispatch-owner.patch
  test ! -e /tmp/webui-kanban-dispatch-owner-ui.patch
  test -x /opt/hermes/.venv/bin/hermes
  test -x /opt/hermes-webui/venv/bin/python || test -x /opt/hermes/.venv/bin/python3
'

log "recreating $SERVICE with compose"
docker compose up -d --no-deps "$SERVICE"

# The recurrent failure mode: when a self-replace is interrupted, compose can
# leave the replacement container in Created. Do not ever call this success.
for attempt in 1 2; do
  sleep 5
  CURRENT_STATE="$(state)"
  log "state after compose attempt $attempt: ${CURRENT_STATE:-missing}"
  if [[ "$CURRENT_STATE" == "running" ]]; then
    break
  fi
  if [[ "$CURRENT_STATE" == "created" ]]; then
    log "container is Created; rerunning scoped compose up to force start"
    docker compose up -d --no-deps "$SERVICE" || docker start "$CONTAINER"
    continue
  fi
  log "container not running; rerunning scoped compose up"
  docker compose up -d --no-deps "$SERVICE"
done

FINAL_STATE="$(state)"
if [[ "$FINAL_STATE" != "running" ]]; then
  log "ERROR: final state is ${FINAL_STATE:-missing}; expected running"
  docker compose ps -a "$SERVICE" || true
  docker logs --tail 120 "$CONTAINER" || true
  exit 1
fi

log "waiting for health"
for i in $(seq 1 30); do
  HEALTH="$(docker inspect "$CONTAINER" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}')"
  log "health attempt $i: $HEALTH"
  [[ "$HEALTH" == "healthy" || "$HEALTH" == "none" ]] && break
  sleep 5
done

log "app-level validation"
docker exec "$CONTAINER" sh -lc '
  set -e
  cd /opt/hermes
  printf "hermes="; git rev-parse HEAD
  printf "webui="; cat /opt/hermes-webui/api/_version.py
  supervisorctl -s unix:///tmp/supervisor.sock status
  wget -qO- http://127.0.0.1:8644/health >/dev/null
  wget -qO- http://127.0.0.1:8787/health >/dev/null
  wget -qO- http://127.0.0.1:9119/api/status >/dev/null
'

log "success: $CONTAINER is running and app health passed"
