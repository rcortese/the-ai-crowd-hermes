#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
usage: promote-moss-compose-candidate.sh \
  --stack-dir DIR --base COMMIT --candidate COMMIT \
  --service NAME --container NAME --execute

Host-side, externally supervised promotion of one compose.yaml-only candidate.
The --execute acknowledgement is mandatory because this command detaches the
stack checkout and force-recreates the selected service. It never builds,
pulls, pushes, or changes another service.
USAGE
}

stack=
base=
candidate=
service=
container=
execute=0
while (($#)); do
  case "$1" in
    --stack-dir) [[ $# -ge 2 ]] || { usage >&2; exit 64; }; stack=$2; shift 2 ;;
    --base) [[ $# -ge 2 ]] || { usage >&2; exit 64; }; base=$2; shift 2 ;;
    --candidate) [[ $# -ge 2 ]] || { usage >&2; exit 64; }; candidate=$2; shift 2 ;;
    --service) [[ $# -ge 2 ]] || { usage >&2; exit 64; }; service=$2; shift 2 ;;
    --container) [[ $# -ge 2 ]] || { usage >&2; exit 64; }; container=$2; shift 2 ;;
    --execute) execute=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done

[[ $execute == 1 && -n $stack && -n $base && -n $candidate && -n $service && -n $container ]] || {
  usage >&2
  exit 64
}
[[ $base =~ ^[0-9a-f]{40}$ && $candidate =~ ^[0-9a-f]{40}$ ]] || {
  echo 'ERROR: base and candidate must be full lowercase Git object IDs' >&2
  exit 64
}
[[ $service =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ && $container =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || {
  echo 'ERROR: invalid service or container name' >&2
  exit 64
}
[[ -d $stack && ! -L $stack ]] || { echo 'ERROR: stack directory missing or unsafe' >&2; exit 66; }
stack=$(realpath "$stack")
[[ -f $stack/compose.yaml && ! -L $stack/compose.yaml ]] || { echo 'ERROR: compose.yaml missing or unsafe' >&2; exit 66; }

self=$(realpath "$0")
[[ -f $self && ! -L $self ]] || { echo 'ERROR: executor source missing or unsafe' >&2; exit 66; }
exec {self_fd}<"$self"
[[ $(stat -Lc '%F' "/proc/$$/fd/$self_fd") == 'regular file' ]] || { echo 'ERROR: executor source is not regular' >&2; exit 66; }
executor_sha=$(sha256sum "/proc/$$/fd/$self_fd" | cut -d' ' -f1)

run_id="compose-candidate-${service}-$(date -u +%Y%m%dT%H%M%SZ)-$$"
run_root="$stack/ops/deploy-runs"
run_dir="$run_root/$run_id"
mkdir -p "$run_root"
mkdir -m 0700 "$run_dir"
cp "/proc/$$/fd/$self_fd" "$run_dir/executor.sh"
chmod 0700 "$run_dir/executor.sh"
[[ $(sha256sum "$run_dir/executor.sh" | cut -d' ' -f1) == "$executor_sha" ]] || {
  echo 'ERROR: executor snapshot mismatch' >&2
  exit 65
}
exec > >(tee -a "$run_dir/run.log") 2>&1

fail() { printf 'FAILED: %s\n' "$*" >&2; exit 1; }
checkout_changed=0
lifecycle_started=0
restore_checkout_on_failure() {
  local rc=$?
  if [[ $rc -ne 0 && $checkout_changed == 1 && $lifecycle_started == 0 ]]; then
    if [[ $(git -C "$stack" rev-parse HEAD 2>/dev/null || true) == "$candidate" ]] \
       && git -C "$stack" diff --quiet \
       && git -C "$stack" diff --cached --quiet; then
      git -C "$stack" checkout --detach "$base" || true
      printf 'checkout_restoration=attempted base=%s\n' "$base" >&2
    else
      printf 'checkout_restoration=blocked reason=checkout_drift\n' >&2
    fi
  fi
  exit "$rc"
}
trap restore_checkout_on_failure EXIT
stream_count() {
  docker exec "$container" curl -fsS --max-time 5 http://127.0.0.1:8787/health |
    jq -er '
      if .status == "ok"
         and (.active_streams | type) == "number"
         and (.active_runs | type) == "number"
         and (.runs | type) == "array"
         and .active_runs == (.runs | length)
      then
        .active_streams, .active_runs
      else
        error("invalid WebUI drain snapshot")
      end
    '
}
probe() {
  docker exec "$container" sh -lc '
    set -eu
    curl -fsS http://127.0.0.1:8787/health >/dev/null
    curl -fsS http://127.0.0.1:8644/health >/dev/null
    curl -fsS http://127.0.0.1:8648/health >/dev/null
  '
  curl -fsS http://127.0.0.1:8644/health >/dev/null
}
read_drain_snapshot() {
  local label=$1 raw
  raw=$(stream_count) || fail "failed to read $label WebUI drain snapshot"
  local -a values
  readarray -t values <<<"$raw"
  test "${#values[@]}" = 2 || fail "$label WebUI drain snapshot has invalid cardinality"
  printf '%s\n%s\n' "${values[0]}" "${values[1]}"
}

[[ $(git -C "$stack" rev-parse HEAD) == "$base" ]] || fail 'primary HEAD drift'
git -C "$stack" diff --quiet || fail 'tracked checkout has unstaged changes'
git -C "$stack" diff --cached --quiet || fail 'tracked checkout has staged changes'
scope_raw=$(git -C "$stack" diff --name-only "$base" "$candidate") || fail 'failed to resolve candidate scope'
readarray -t scope <<<"$scope_raw"
[[ ${#scope[@]} == 1 && ${scope[0]} == compose.yaml ]] || fail 'candidate scope is not compose.yaml only'
docker compose --project-directory "$stack" -f "$stack/compose.yaml" config -q

pre=$(docker inspect "$container")
printf '%s\n' "$pre" >"$run_dir/pre-live.json"
pre_image=$(jq -r '.[0].Image' <<<"$pre")
pre_id=$(jq -r '.[0].Id' <<<"$pre")
pre_started=$(jq -r '.[0].State.StartedAt' <<<"$pre")
pre_restarts=$(jq -r '.[0].RestartCount' <<<"$pre")

first_raw=$(read_drain_snapshot first)
readarray -t first <<<"$first_raw"
printf 'first_streams=%s first_active_runs=%s\n' "${first[0]}" "${first[1]}" | tee "$run_dir/drain.txt"
test "${first[0]}" = 0 || fail 'active streams present'
test "${first[1]}" = 0 || fail 'active background runs present'
sleep 15

second_raw=$(read_drain_snapshot second)
readarray -t second <<<"$second_raw"
printf 'second_streams=%s second_active_runs=%s\n' "${second[0]}" "${second[1]}" | tee -a "$run_dir/drain.txt"
test "${second[0]}" = 0 || fail 'active streams appeared during drain'
test "${second[1]}" = 0 || fail 'active background runs appeared during drain'

[[ $(git -C "$stack" rev-parse HEAD) == "$base" ]] || fail 'primary HEAD changed during drain'
git -C "$stack" diff --quiet || fail 'tracked checkout changed during drain'
git -C "$stack" diff --cached --quiet || fail 'tracked index changed during drain'
docker inspect "$container" --format '{{.Id}} {{.Image}} {{.State.StartedAt}} {{.RestartCount}} {{.State.Health.Status}}' |
  grep -F -x "$pre_id $pre_image $pre_started $pre_restarts healthy" >/dev/null || fail 'live Moss changed during drain'

git -C "$stack" checkout --detach "$candidate"
checkout_changed=1
[[ $(git -C "$stack" rev-parse HEAD) == "$candidate" ]] || fail 'candidate checkout did not bind'
git -C "$stack" diff --quiet || fail 'candidate checkout unexpectedly dirty'
git -C "$stack" diff --cached --quiet || fail 'candidate index unexpectedly dirty'
docker compose --project-directory "$stack" -f "$stack/compose.yaml" config -q

final_raw=$(read_drain_snapshot final)
readarray -t final <<<"$final_raw"
printf 'final_streams=%s final_active_runs=%s\n' "${final[0]}" "${final[1]}" | tee -a "$run_dir/drain.txt"
test "${final[0]}" = 0 || fail 'active streams appeared immediately before lifecycle'
test "${final[1]}" = 0 || fail 'active background runs appeared immediately before lifecycle'

# Exact existing image only: no build, pull, dependency recreation, or sibling service.
lifecycle_started=1
docker compose --project-directory "$stack" -f "$stack/compose.yaml" up -d \
  --no-build --no-deps --force-recreate --wait --wait-timeout 120 "$service"
probe

post=$(docker inspect "$container")
printf '%s\n' "$post" >"$run_dir/post-live.json"
post_image=$(jq -r '.[0].Image' <<<"$post")
post_id=$(jq -r '.[0].Id' <<<"$post")
post_started=$(jq -r '.[0].State.StartedAt' <<<"$post")
post_restarts=$(jq -r '.[0].RestartCount' <<<"$post")
post_health=$(jq -r '.[0].State.Health.Status' <<<"$post")
[[ $post_image == "$pre_image" ]] || fail 'unexpected image change'
[[ $post_id != "$pre_id" ]] || fail 'service was not recreated'
[[ $post_started != "$pre_started" ]] || fail 'service start time did not change'
[[ $post_health == healthy ]] || fail 'post-promotion health is not healthy'

jq -nc \
  --arg run_id "$run_id" --arg candidate "$candidate" --arg base "$base" \
  --arg service "$service" --arg container "$container" \
  --arg executor_path "$run_dir/executor.sh" --arg executor_sha "$executor_sha" \
  --arg pre_image "$pre_image" --arg pre_id "$pre_id" --arg pre_started "$pre_started" --argjson pre_restarts "$pre_restarts" \
  --arg post_image "$post_image" --arg post_id "$post_id" --arg post_started "$post_started" --argjson post_restarts "$post_restarts" \
  --arg drain_sha256 "$(sha256sum "$run_dir/drain.txt" | cut -d' ' -f1)" \
  '{schema_version:1,run_id:$run_id,candidate_commit:$candidate,base_commit:$base,scope:["compose.yaml"],executor:{path:$executor_path,sha256:$executor_sha},drain:{evidence_sha256:$drain_sha256,stable_zero_observations:3,source:"target-server-health-endpoint"},pre:{image_id:$pre_image,container_id:$pre_id,started_at:$pre_started,restart_count:$pre_restarts},post:{image_id:$post_image,container_id:$post_id,started_at:$post_started,restart_count:$post_restarts},activation:{service:$service,container:$container,build:false,pull:false,no_deps:true,force_recreate:true},verification:{container_endpoints:["8787/health","8644/health","8648/health"],host_endpoint:"8644/health"},result:"SUCCEEDED"}' \
  >"$run_dir/terminal.json"
chmod 0600 "$run_dir/terminal.json"
printf '%s\n' "$run_dir" >"$run_root/latest-compose-candidate-promotion"
printf 'SUCCEEDED run_dir=%s terminal_sha256=%s\n' "$run_dir" "$(sha256sum "$run_dir/terminal.json" | cut -d' ' -f1)"
