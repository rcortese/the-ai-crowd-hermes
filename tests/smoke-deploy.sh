#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_REF="${MOSS_SMOKE_IMAGE:-${MOSS_IMAGE_REF:-}}"
[[ -n $IMAGE_REF ]] || { printf '%s\n' 'smoke_deploy_blocked: set MOSS_SMOKE_IMAGE to the explicit candidate image' >&2; exit 2; }
command -v docker >/dev/null 2>&1 || { printf '%s\n' 'smoke_deploy_blocked: docker CLI unavailable' >&2; exit 2; }
docker info >/dev/null 2>&1 || { printf '%s\n' 'smoke_deploy_blocked: docker daemon unavailable' >&2; exit 2; }

MOSS_SMOKE_IMAGE_ID=$(docker image inspect "$IMAGE_REF" --format '{{.Id}}') || { printf '%s\n' 'smoke_deploy_blocked: candidate image unavailable' >&2; exit 2; }
[[ $MOSS_SMOKE_IMAGE_ID =~ ^sha256:[0-9a-f]{64}$ ]] || { printf '%s\n' 'smoke_deploy_blocked: invalid candidate image ID' >&2; exit 2; }
export MOSS_SMOKE_IMAGE_ID

production_container=the-ai-crowd-moss-1
production_before=$(docker inspect "$production_container" --format '{{.Id}}|{{.Image}}|{{.State.StartedAt}}|{{.RestartCount}}') || {
  printf '%s\n' 'smoke_deploy_blocked: production Moss identity unavailable' >&2
  exit 2
}

project="moss-accept-$(date -u +%s)-$$"
[[ $project != the-ai-crowd && $project == moss-accept-* ]] || { printf '%s\n' 'smoke_deploy_blocked: unsafe project identity' >&2; exit 2; }
smoke_root=$(mktemp -d "${TMPDIR:-/tmp}/moss-candidate-smoke.XXXXXX")
export MOSS_SMOKE_ROOT="$smoke_root"
override="$smoke_root/compose.smoke.yaml"
config_out="$smoke_root/rendered.yaml"
compose=()
armed=0

on_exit(){
  local rc=$? after=
  trap - EXIT INT TERM
  if ((armed)); then
    if ! "${compose[@]}" down --remove-orphans --volumes >/dev/null 2>&1; then
      ((rc==0)) && rc=81
    fi
  fi
  if ! after=$(docker inspect "$production_container" --format '{{.Id}}|{{.Image}}|{{.State.StartedAt}}|{{.RestartCount}}' 2>/dev/null); then
    printf '%s\n' 'smoke_deploy_failed: production identity unavailable after smoke' >&2
    ((rc==0)) && rc=82
  fi
  if [[ $after != "$production_before" ]]; then
    printf 'smoke_deploy_failed: production identity changed before=%s after=%s\n' "$production_before" "$after" >&2
    ((rc==0)) && rc=83
  fi
  rm -rf -- "$smoke_root"
  exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

install -d -m 0755 "$smoke_root/env" "$smoke_root/public" "$smoke_root/archive"
install -d -m 0770 "$smoke_root/runtime" "$smoke_root/private" "$smoke_root/shared" "$smoke_root/backups"
chown -R 99:100 "$smoke_root/runtime" "$smoke_root/private" "$smoke_root/shared" "$smoke_root/backups"
cp -- "$ROOT/compose.yaml" "$smoke_root/compose.yaml"
: >"$smoke_root/env/fleet.env"
: >"$smoke_root/env/moss-webui.env"
: >"$smoke_root/env/roy.env"

cat >"$override" <<'YAML'
services:
  moss:
    image: ${MOSS_SMOKE_IMAGE_ID}
    restart: "no"
    user: "99:100"
    ports: !reset []
    networks: !reset [smoke]
    env_file: !reset []
    environment:
      API_SERVER_KEY: moss-smoke-isolated-api-key
      TELEGRAM_BOT_TOKEN: ''
    volumes: !override
      - ${MOSS_SMOKE_ROOT}/runtime:/opt/data
      - ${MOSS_SMOKE_ROOT}/public:/agents/moss/public:ro
      - ${MOSS_SMOKE_ROOT}/private:/agents/moss/private:rw
      - ${MOSS_SMOKE_ROOT}/shared:/mnt/hermes-shared
      - ${MOSS_SMOKE_ROOT}/archive:/archiveops/richmond:ro
      - ${MOSS_SMOKE_ROOT}/backups:/mnt/user/backups/the-ai-crowd:rw
networks:
  smoke: {}
YAML

compose=(docker compose --project-name "$project" --project-directory "$smoke_root" -f "$smoke_root/compose.yaml" -f "$override")
THE_AI_CROWD_IMAGE_TAG=unused MOSS_IMAGE_REF="$MOSS_SMOKE_IMAGE_ID" "${compose[@]}" config >"$config_out"
armed=1
THE_AI_CROWD_IMAGE_TAG=unused MOSS_IMAGE_REF="$MOSS_SMOKE_IMAGE_ID" "${compose[@]}" up -d --no-build --no-deps moss
container_id=$("${compose[@]}" ps -q moss)
[[ -n $container_id ]] || { printf '%s\n' 'smoke_deploy_failed: candidate container missing' >&2; exit 1; }
[[ $(docker inspect "$container_id" --format '{{.Image}}') == "$MOSS_SMOKE_IMAGE_ID" ]] || {
  printf '%s\n' 'smoke_deploy_failed: candidate container image mismatch' >&2
  exit 1
}
"${compose[@]}" exec -T moss sh -lc 'test "${API_SERVER_KEY:-}" = moss-smoke-isolated-api-key' || {
  printf '%s\n' 'smoke_deploy_failed: isolated API key missing' >&2
  exit 1
}
for _ in $(seq 1 45); do
  if "${compose[@]}" exec -T moss sh -lc 'curl -fsS http://127.0.0.1:8787/health >/dev/null && curl -fsS http://127.0.0.1:8648/health >/dev/null'; then
    printf 'smoke_deploy_ok project=%s image=%s root=temporary production=unchanged\n' "$project" "$MOSS_SMOKE_IMAGE_ID"
    exit 0
  fi
  sleep 2
done
"${compose[@]}" ps moss >&2 || true
"${compose[@]}" logs --tail 120 moss >&2 || true
printf '%s\n' 'smoke_deploy_failed: candidate health endpoints not ready' >&2
exit 1
