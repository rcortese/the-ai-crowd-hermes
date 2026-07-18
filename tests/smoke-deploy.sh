#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

project="the-ai-crowd-smoke"
started=false
config_out="$(mktemp -t the-ai-crowd-smoke-config.XXXXXX.yaml)"
override_out="$(mktemp -t the-ai-crowd-smoke-override.XXXXXX.yaml)"
smoke_runtime_home="$(mktemp -d -t the-ai-crowd-smoke-runtime.XXXXXX)"
compose=()
created_env_files=()
cleanup() {
  if [[ "$started" == "true" ]]; then
    "${compose[@]}" down --remove-orphans >/dev/null 2>&1 || true
  fi
  if ((${#created_env_files[@]})); then
    rm -f "${created_env_files[@]}"
  fi
  find "$smoke_runtime_home" -depth -delete 2>/dev/null || true
  rmdir "$smoke_runtime_home" 2>/dev/null || true
  rm -f "$config_out" "$override_out"
}
trap cleanup EXIT

if ! command -v docker >/dev/null 2>&1; then
  echo "smoke_deploy_blocked: docker CLI not available"
  exit 2
fi
if ! docker info >/dev/null 2>&1; then
  echo "smoke_deploy_blocked: docker daemon unavailable"
  exit 2
fi

# Compose validates env_file paths before service overrides. Create empty
# placeholders only for missing ignored files and remove them on exit.
for env_file in env/fleet.env env/moss-webui.env env/roy.env; do
  if [[ ! -e "$env_file" ]]; then
    mkdir -p "$(dirname "$env_file")"
    : >"$env_file"
    created_env_files+=("$env_file")
  elif [[ ! -f "$env_file" ]]; then
    printf 'smoke_deploy_blocked: env path is not a regular file: %s\n' "$env_file" >&2
    exit 2
  fi
done

# All programs run as the Hermes UID, so an owner-only host tmpdir would make
# the isolated runtime unreadable. Pre-create the gateway log directory too:
# Compose launches supervisord as root while its child gateway drops to Hermes.
mkdir -p "$smoke_runtime_home/logs"
chown 99:100 "$smoke_runtime_home" "$smoke_runtime_home/logs"
export smoke_runtime_home

# The production file intentionally publishes Moss on 8644 and attaches it to
# shared external networks.  Reset both for the smoke project so it cannot
# claim a production port or join a production network.
cat >"$override_out" <<'YAML'
services:
  moss:
    # A fresh smoke home has no root-owned bootstrap state. Run as the Hermes
    # UID so every startup artifact is owned by the process that consumes it.
    user: "99:100"
    ports: !reset []
    networks: !reset [smoke]
    # Production env files are deliberately untracked. The smoke gets only
    # its explicit non-secret environment and must not depend on their paths.
    env_file: !reset []
    environment:
      # The API server requires a key even on an isolated private network.
      # This is a smoke-only capability, never a production credential.
      API_SERVER_KEY: moss-smoke-isolated-api-key
      TELEGRAM_BOT_TOKEN: ''
    volumes: !override
      - ${smoke_runtime_home}:/opt/data
      - ./agents/public/moss:/agents/moss/public:ro
      - ./agents/private/moss:/agents/moss/private:rw
      - ./state/shared:/mnt/hermes-shared
      - ./agents/private/richmond-archiveops:/archiveops/richmond:ro
      - ${THE_AI_CROWD_BACKUP_ROOT:-./state/private/backups}:/mnt/user/backups/the-ai-crowd:rw
networks:
  smoke: {}
YAML

compose=(docker compose -p "$project" -f compose.yaml -f "$override_out")
"${compose[@]}" config >"$config_out"
# Arm cleanup before up: Compose can create a subset of resources and then
# fail, and that partial state must not survive a smoke failure.
started=true
"${compose[@]}" up -d --build moss
"${compose[@]}" exec -T moss sh -lc 'test "${API_SERVER_KEY:-}" = moss-smoke-isolated-api-key' || {
  echo "smoke_deploy_failed: isolated API key missing from moss container" >&2
  exit 1
}
for attempt in $(seq 1 30); do
  # The generic webhook listener (8644) requires persisted routes and their
  # HMAC secrets, intentionally absent from this fresh non-secret runtime.
  # Validate it only after production recreate, against production's routes.
  if "${compose[@]}" exec -T moss sh -lc 'curl -fsS http://127.0.0.1:8787/health >/dev/null && curl -fsS http://127.0.0.1:8648/health >/dev/null'; then
    "${compose[@]}" ps moss
    echo "smoke_deploy_ok"
    exit 0
  fi
  status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${project}-moss-1" 2>/dev/null || true)"
  if [[ "$status" == "exited" || "$status" == "dead" ]]; then
    "${compose[@]}" ps moss || true
    "${compose[@]}" logs --tail 120 moss || true
    "${compose[@]}" logs moss 2>&1 | grep -Ei 'api.server|api_server|8648|webhook|8644|refus|error' | tail -120 || true
    echo "smoke_deploy_failed: moss container status=$status"
    exit 1
  fi
  sleep 2
done

"${compose[@]}" ps moss || true
"${compose[@]}" logs --tail 120 moss || true
"${compose[@]}" logs moss 2>&1 | grep -Ei 'api.server|api_server|8648|webhook|8644|refus|error' | tail -120 || true
echo "smoke_deploy_failed: moss health endpoints not ready after bounded wait"
exit 1
