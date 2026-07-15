#!/usr/bin/env bash
# Detached, durable owner of the only Moss lifecycle transition.  It never
# accepts mutable tags as identity and always records a terminal state.
set -Eeuo pipefail
usage() { printf '%s\n' 'usage: moss-promotion-guardian.sh --state ABSOLUTE_DIR --execute'; }
die() { printf '%s\n' "$*" >&2; exit 1; }
state= execute=0
while (($#)); do
  case $1 in
    --state) (($# >= 2)) || { usage >&2; exit 64; }; state=$2; shift 2 ;;
    --execute) execute=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done
[[ $execute == 1 && $state == /* && -d $state && ! -L $state ]] || die 'guardian requires an absolute regular state directory and --execute'
readonly deployment_root=/mnt/user/appdata/the-ai-crowd
readonly container=the-ai-crowd-moss-1 readonly service=moss readonly production_image=the-ai-crowd/moss-all-in-one:local
compose=(docker compose --project-directory "$deployment_root" --env-file "$deployment_root/.env" -f "$deployment_root/compose.yaml")
write_status() { printf '%s\n' "$1" >"$state/status"; }
need() { [[ -s $state/$1 ]] || die "missing guardian evidence: $1"; }
for item in candidate-image-id activation-live-image-id activation-container activation-container-id activation-candidate-image-id; do need "$item"; done
candidate=$(<"$state/candidate-image-id"); rollback_image=$(<"$state/activation-live-image-id")
[[ $candidate =~ ^sha256:[[:xdigit:]]{64}$ && $rollback_image =~ ^sha256:[[:xdigit:]]{64}$ ]] || die 'invalid immutable image evidence'
[[ $(<"$state/activation-container") == "$container" ]] || die 'canonical container mismatch'
read_live() { docker inspect -f '{{.Id}}|{{.Image}}' "$container"; }
assert_cas() {
  local actual candidate_actual
  actual=$(read_live) || die 'canonical container unavailable'
  [[ $actual == "$(<"$state/activation-container-id")|$rollback_image" ]] || die 'guardian CAS mismatch: live target changed'
  candidate_actual=$(docker image inspect -f '{{.Id}}' "the-ai-crowd/moss-all-in-one:write-safe-root-$(<"$state/commit")") || die 'guardian CAS mismatch: candidate missing'
  [[ $candidate_actual == "$candidate" && $(<"$state/activation-candidate-image-id") == "$candidate" ]] || die 'guardian CAS mismatch: candidate changed'
}
health_idle() {
  docker exec "$container" sh -lc 'curl -fsS http://127.0.0.1:8787/health' | jq -e 'type == "object" and .status == "ok" and (.active_streams|type == "number") and (.active_runs|type == "number") and .active_streams == 0 and .active_runs == 0' >/dev/null
}
admit_idle() { health_idle && sleep 5 && health_idle; }
probe_ready() {
  local expected=$1 observed
  observed=$(docker inspect -f '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}|{{.Image}}' "$container")
  [[ $observed == "running|healthy|$expected" ]] || return 1
  docker exec "$container" sh -lc 'curl -fsS http://127.0.0.1:8787/health >/dev/null && curl -fsS http://127.0.0.1:8644/health >/dev/null && curl -fsS http://127.0.0.1:9119/ >/dev/null'
  curl -fsS -o /dev/null -w '%{http_code}' https://hermes.rodolflix.com/ | grep -Eq '^(200|401|403)$'
}
rollback() {
  write_status rolling_back
  docker image tag "$rollback_image" "$production_image"
  "${compose[@]}" up -d --no-deps --force-recreate --wait --wait-timeout 180 "$service"
  probe_ready "$rollback_image" || { write_status rollback_failed; return 1; }
  write_status rollback_ready
}
write_status guardian_started
if ! admit_idle; then write_status admission_blocked; exit 2; fi
assert_cas
printf '%s\n' "$rollback_image" >"$state/rollback-image"
write_status activating
docker image tag "$candidate" "$production_image"
if ! "${compose[@]}" up -d --no-deps --force-recreate --wait --wait-timeout 180 "$service"; then rollback; exit 1; fi
if ! probe_ready "$candidate"; then rollback; exit 1; fi
rm -f "$state/rollback-image"
write_status promote_complete
