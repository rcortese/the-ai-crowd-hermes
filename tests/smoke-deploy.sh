#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

project="the-ai-crowd-hermes-smoke"
started=false
config_out="$(mktemp -t the-ai-crowd-hermes-smoke-config.XXXXXX.yaml)"
cleanup() {
  if [[ "$started" == "true" ]]; then
    docker compose -p "$project" down --remove-orphans >/dev/null 2>&1 || true
  fi
  rm -f "$config_out"
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

docker compose -p "$project" config >"$config_out"
docker compose -p "$project" up -d --build moss
started=true

for attempt in $(seq 1 30); do
  if docker compose -p "$project" exec -T moss sh -lc 'curl -fsS http://127.0.0.1:9119/ >/dev/null'; then
    docker compose -p "$project" ps moss
    echo "smoke_deploy_ok"
    exit 0
  fi
  status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${project}-moss-1" 2>/dev/null || true)"
  if [[ "$status" == "exited" || "$status" == "dead" ]]; then
    docker compose -p "$project" ps moss || true
    echo "smoke_deploy_failed: moss container status=$status"
    exit 1
  fi
  sleep 2
done

docker compose -p "$project" ps moss || true
echo "smoke_deploy_failed: dashboard not ready after bounded wait"
exit 1
