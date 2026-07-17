#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  echo "usage: $0 [--rehearse] [--rollback-only] --expected-rollback-image-id ID --candidate-image-id ID --expected-stack-commit SHA --result PATH" >&2
  exit 64
}

mode=production
operation=promote
expected_rollback_image_id=
candidate_image_id=
expected_stack_commit=
result_path=
while (($#)); do
  case "$1" in
    --rehearse) mode=rehearsal; shift ;;
    --rollback-only) operation=rollback_only; shift ;;
    --expected-rollback-image-id) [[ $# -ge 2 ]] || usage; expected_rollback_image_id=$2; shift 2 ;;
    --candidate-image-id) [[ $# -ge 2 ]] || usage; candidate_image_id=$2; shift 2 ;;
    --expected-stack-commit) [[ $# -ge 2 ]] || usage; expected_stack_commit=$2; shift 2 ;;
    --result) [[ $# -ge 2 ]] || usage; result_path=$2; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$expected_rollback_image_id" && -n "$candidate_image_id" && -n "$expected_stack_commit" && -n "$result_path" ]] || usage
[[ "$expected_rollback_image_id" =~ ^sha256:[0-9a-f]{64}$ && "$candidate_image_id" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "ERROR: image IDs must be canonical immutable sha256 IDs" >&2; exit 64; }
[[ "$expected_rollback_image_id" != "$candidate_image_id" ]] || { echo "ERROR: rollback and candidate image IDs are identical" >&2; exit 64; }
[[ "$expected_stack_commit" =~ ^[0-9a-f]{40}$ ]] || { echo "ERROR: expected stack commit must be a full SHA" >&2; exit 64; }

compose_root=/mnt/user/appdata/the-ai-crowd
project=the-ai-crowd
service=moss
container_name=the-ai-crowd-moss-1
image_ref=the-ai-crowd/moss-all-in-one:local
result_root=/mnt/user/appdata/the-ai-crowd/state/shared/kanban/artifacts/hermes-webui-detailed-health-auth-20260713/cutover
lock_file="$result_root/deploy.lock"
if [[ "$mode" == rehearsal ]]; then
  compose_root=${MOSS_DEPLOY_COMPOSE_ROOT:?MOSS_DEPLOY_COMPOSE_ROOT is required for rehearsal}
  project=${MOSS_DEPLOY_PROJECT:?MOSS_DEPLOY_PROJECT is required for rehearsal}
  service=${MOSS_DEPLOY_SERVICE:-moss}
  container_name=${MOSS_DEPLOY_CONTAINER_NAME:?MOSS_DEPLOY_CONTAINER_NAME is required for rehearsal}
  image_ref=${MOSS_DEPLOY_IMAGE_REF:?MOSS_DEPLOY_IMAGE_REF is required for rehearsal}
  lock_file=${MOSS_DEPLOY_LOCK_FILE:?MOSS_DEPLOY_LOCK_FILE is required for rehearsal}
  [[ "$compose_root" != /mnt/user/appdata/the-ai-crowd ]]
  [[ "$project" == moss-health-auth-rehearsal-* ]]
else
  [[ "$result_path" == "$result_root"/*/result.json ]] || { echo "ERROR: production result path is outside the bounded cutover root" >&2; exit 64; }
fi

[[ -f "$compose_root/compose.yaml" ]] || { echo "ERROR: missing compose file" >&2; exit 66; }
[[ "$(git -C "$compose_root" rev-parse HEAD)" == "$expected_stack_commit" ]] || { echo "ERROR: stack commit mismatch" >&2; exit 65; }
mkdir -p "$(dirname "$result_path")" "$(dirname "$lock_file")"
exec 9>"$lock_file"
flock -n 9 || { echo "ERROR: another Moss deploy is active" >&2; exit 75; }

compose=(docker compose -p "$project" -f "$compose_root/compose.yaml")
health_timeout_s=${MOSS_DEPLOY_HEALTH_TIMEOUT_S:-180}
[[ "$health_timeout_s" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: invalid health timeout" >&2; exit 64; }

atomic_result() {
  local status=$1 reason=$2 active_image_id=$3 active_container_id=$4 healthy=$5
  local tmp="${result_path}.tmp.$$"
  printf '{"status":"%s","reason":"%s","mode":"%s","operation":"%s","service":"%s","active_image_id":"%s","active_container_id":"%s","healthy":%s,"candidate_image_id":"%s","rollback_image_id":"%s","stack_commit":"%s"}\n' \
    "$status" "$reason" "$mode" "$operation" "$service" "$active_image_id" "$active_container_id" "$healthy" "$candidate_image_id" "$expected_rollback_image_id" "$expected_stack_commit" > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$result_path"
}

image_id() {
  docker image inspect "$1" --format '{{.Id}}'
}
container_image_id() {
  docker inspect "$1" --format '{{.Image}}'
}
wait_healthy() {
  local cid=$1 deadline=$(( $(date +%s) + health_timeout_s )) status
  while (( $(date +%s) <= deadline )); do
    status=$(docker inspect "$cid" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)
    [[ "$status" == healthy ]] && return 0
    [[ "$status" == exited || "$status" == dead || "$status" == unhealthy ]] && return 1
    sleep 2
  done
  return 1
}

[[ "$(image_id "$expected_rollback_image_id")" == "$expected_rollback_image_id" ]] || { echo "ERROR: rollback image ID unavailable" >&2; exit 66; }
[[ "$(image_id "$candidate_image_id")" == "$candidate_image_id" ]] || { echo "ERROR: candidate image ID unavailable" >&2; exit 66; }
current_cid=$("${compose[@]}" ps -q "$service")
[[ -n "$current_cid" ]] || { echo "ERROR: Moss container is absent" >&2; exit 69; }
[[ "$(docker inspect "$current_cid" --format '{{.Name}}')" == "/$container_name" ]] || { echo "ERROR: container identity mismatch" >&2; exit 65; }
if [[ "$operation" == promote ]]; then
  [[ "$(container_image_id "$current_cid")" == "$expected_rollback_image_id" ]] || { echo "ERROR: running image does not match expected rollback image" >&2; exit 65; }
else
  [[ "$(container_image_id "$current_cid")" == "$candidate_image_id" ]] || { echo "ERROR: rollback-only requires the expected candidate image to be running" >&2; exit 65; }
fi

mutated=0
completed=0
rollback() {
  local reason=$1
  set +e
  docker image tag "$expected_rollback_image_id" "$image_ref"
  "${compose[@]}" up -d --no-deps --force-recreate "$service"
  local rollback_cid rollback_active
  rollback_cid=$("${compose[@]}" ps -q "$service")
  rollback_active=$(container_image_id "$rollback_cid" 2>/dev/null)
  if [[ "$rollback_active" == "$expected_rollback_image_id" ]] && wait_healthy "$rollback_cid"; then
    atomic_result rolled_back "$reason" "$rollback_active" "$rollback_cid" true
    return 0
  fi
  atomic_result rollback_failed "$reason" "${rollback_active:-unknown}" "${rollback_cid:-unknown}" false
  return 1
}
on_error() {
  local rc=$?
  if (( mutated == 1 && completed == 0 )); then
    rollback "promotion_failed_rc_${rc}" || true
  fi
  exit "$rc"
}
trap on_error ERR INT TERM

if [[ "$operation" == rollback_only ]]; then
  if rollback post_promotion_validation_failed; then
    rollback_rc=0
  else
    rollback_rc=$?
  fi
  set -e
  completed=1
  trap - ERR INT TERM
  if (( rollback_rc != 0 )); then
    exit "$rollback_rc"
  fi
  printf 'ROLLED_BACK service=%s image_id=%s result=%s\n' "$service" "$expected_rollback_image_id" "$result_path"
  exit 0
fi

docker image tag "$candidate_image_id" "$image_ref"
mutated=1
[[ "$(image_id "$image_ref")" == "$candidate_image_id" ]]
"${compose[@]}" up -d --no-deps --force-recreate "$service"
new_cid=$("${compose[@]}" ps -q "$service")
[[ -n "$new_cid" ]]
[[ "$(docker inspect "$new_cid" --format '{{.Name}}')" == "/$container_name" ]]
[[ "$(container_image_id "$new_cid")" == "$candidate_image_id" ]]
wait_healthy "$new_cid"
completed=1
atomic_result promoted candidate_healthy "$candidate_image_id" "$new_cid" true
trap - ERR INT TERM
printf 'PROMOTED service=%s image_id=%s result=%s\n' "$service" "$candidate_image_id" "$result_path"
