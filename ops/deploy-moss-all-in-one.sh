#!/usr/bin/env bash
set -euo pipefail

# Host-side Moss all-in-one self-replace helper.
# Run on the Docker host (Unraid/media), not from inside the Moss container.
# The point is to keep the observer/recovery loop alive while Moss is replaced.

STACK_DIR="${STACK_DIR:-/mnt/user/appdata/the-ai-crowd}"
SERVICE="${SERVICE:-moss}"
CONTAINER="${CONTAINER:-the-ai-crowd-moss-1}"
IMAGE="${IMAGE:-the-ai-crowd/moss-all-in-one:local}"
SELF_REPLACE_DELAY_SECONDS="${SELF_REPLACE_DELAY_SECONDS:-5}"
MAX_HEALTH_ATTEMPTS="${MAX_HEALTH_ATTEMPTS:-30}"
HEALTH_SLEEP_SECONDS="${HEALTH_SLEEP_SECONDS:-5}"

TS="${TS:-$(date +%Y%m%dT%H%M%S%z)}"
RUN_DIR="${RUN_DIR:-/mnt/user/appdata/the-ai-crowd/runtime/moss-home/ops/cutovers/${TS}-self-replace}"
LOG_FILE="${LOG_FILE:-$RUN_DIR/deploy.log}"
SUCCESS_MARKER="${SUCCESS_MARKER:-/mnt/user/appdata/the-ai-crowd/runtime/moss-home/ops/cutovers/latest-self-replace-success}"

mkdir -p "$RUN_DIR"
chmod 0700 "$RUN_DIR" || true

if [[ -z "${SELF_REPLACE_INNER:-}" ]]; then
  # Relaunch detached unless the caller explicitly opted out. This makes the
  # helper safe to start from a live Moss tool call: the host process survives
  # the container replacement and continues writing logs/markers.
  if [[ "${SELF_REPLACE_DETACH:-1}" == "1" ]]; then
    SELF_REPLACE_INNER=1 nohup "$0" "$@" >"$LOG_FILE" 2>&1 < /dev/null &
    printf '%s\n' "$RUN_DIR"
    exit 0
  fi
fi

exec > >(tee -a "$LOG_FILE") 2>&1

log() { printf '[moss-self-replace] %s %s\n' "$(date -Is)" "$*"; }
state() { docker inspect "$CONTAINER" --format '{{.State.Status}}' 2>/dev/null || true; }
health() { docker inspect "$CONTAINER" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null || true; }

log "run_dir=$RUN_DIR"
log "stack_dir=$STACK_DIR service=$SERVICE container=$CONTAINER image=$IMAGE"
cd "$STACK_DIR"

log 'rendering compose model'
docker compose config --quiet

log 'building target service image'
DOCKER_BUILDKIT=1 docker compose build "$SERVICE"

log 'one-shot image preflight'
docker run --rm --entrypoint sh "$IMAGE" -lc '
  set -e
  cd /opt/hermes
  git rev-parse HEAD
  test -x /opt/hermes/.venv/bin/hermes
  test ! -e /tmp/kanban-dispatch-owner.patch
  test ! -e /tmp/webui-kanban-dispatch-owner-ui.patch
  if [ -e /opt/hermes-webui/api/_version.py ]; then cat /opt/hermes-webui/api/_version.py; fi
'

log "sleeping ${SELF_REPLACE_DELAY_SECONDS}s before self-replace"
sleep "$SELF_REPLACE_DELAY_SECONDS"

log 'running scoped compose up'
docker compose up -d --no-deps "$SERVICE"

sleep 5
current="$(state)"
log "docker state after initial compose up: ${current:-missing}"
if [[ "$current" != "running" ]]; then
  if [[ "$current" == "created" ]]; then
    log 'state is Created: compose created but did not start the replacement; making one host-side recovery attempt'
    docker compose up -d --no-deps "$SERVICE" || docker start "$CONTAINER"
  else
    log 'state is not running; making one scoped host-side compose recovery attempt'
    docker compose up -d --no-deps "$SERVICE"
  fi
  sleep 5
fi

final_state="$(state)"
if [[ "$final_state" != "running" ]]; then
  log "FAILED: final state is ${final_state:-missing}; expected running"
  docker compose ps -a "$SERVICE" || true
  docker logs --tail 160 "$CONTAINER" || true
  exit 1
fi

log 'waiting for Docker health'
for i in $(seq 1 "$MAX_HEALTH_ATTEMPTS"); do
  h="$(health)"
  log "health attempt $i: ${h:-missing}"
  if [[ "$h" == "healthy" || "$h" == "none" ]]; then
    break
  fi
  sleep "$HEALTH_SLEEP_SECONDS"
done

final_health="$(health)"
if [[ "$final_health" != "healthy" && "$final_health" != "none" ]]; then
  log "FAILED: final health is ${final_health:-missing}"
  docker compose ps -a "$SERVICE" || true
  docker logs --tail 160 "$CONTAINER" || true
  exit 1
fi

log 'validating app-level endpoints inside container'
docker exec "$CONTAINER" sh -lc '
  set -e
  cd /opt/hermes
  printf "hermes="; git rev-parse HEAD
  if [ -e /opt/hermes-webui/api/_version.py ]; then printf "webui="; cat /opt/hermes-webui/api/_version.py; fi
  wget -qO- http://127.0.0.1:8644/health >/dev/null
  wget -qO- http://127.0.0.1:8787/health >/dev/null
  wget -qO- http://127.0.0.1:9119/api/status >/dev/null
'

log 'validating host-visible gateway endpoint'
curl -fsS http://127.0.0.1:8644/health >/dev/null

date -Is > "$SUCCESS_MARKER"
printf '%s\n' "$RUN_DIR" > /mnt/user/appdata/the-ai-crowd/runtime/moss-home/ops/cutovers/latest-self-replace-run-dir
log "SUCCESS marker=$SUCCESS_MARKER"
