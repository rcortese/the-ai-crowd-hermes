#!/usr/bin/env bash
# Detached, durable owner of the only Moss lifecycle transition.
# It accepts immutable image IDs only, fences ingress before its final idle
# assertion, serializes the lifecycle, and leaves a terminal receipt.
set -Eeuo pipefail
usage() { printf '%s\n' 'usage: moss-promotion-guardian.sh --state ABSOLUTE_DIR --execute'; }
state= execute=0
while (($#)); do
  case $1 in
    --state) (($# >= 2)) || { usage >&2; exit 64; }; state=$2; shift 2 ;;
    --execute) execute=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done
[[ $execute == 1 && $state == /* && -d $state && ! -L $state ]] || { usage >&2; exit 64; }
readonly deployment_root=/mnt/user/appdata/the-ai-crowd
readonly container=the-ai-crowd-moss-1 service=moss production_image=the-ai-crowd/moss-all-in-one:local
readonly ingress_network=network_default lock_path="$deployment_root/state/shared/moss-promotion.lock"
admission_wait_seconds=${MOSS_PROMOTION_ADMISSION_WAIT_SECONDS:-1800}
[[ $admission_wait_seconds =~ ^[0-9]+$ ]] || { printf "invalid admission wait\n" >&2; exit 64; }
compose=(docker compose --project-directory "$deployment_root" --env-file "$deployment_root/.env" -f "$deployment_root/compose.yaml")
fenced=0 transition_started=0 terminal=0
write_status() { printf '%s\n' "$1" >"$state/status"; }
terminal_status() { terminal=1; write_status "$1"; }
fail() { terminal_status "guardian_failed:$1"; printf '%s\n' "$1" >&2; exit 1; }
restore_fence() {
  [[ $fenced == 1 ]] || return 0
  docker network connect --alias moss --alias hermes "$ingress_network" "$container" 2>/dev/null || true
  docker exec "$container" supervisorctl -c /etc/supervisor/conf.d/moss-all-in-one.conf start moss-gateway >/dev/null 2>&1 || true
  fenced=0
}
on_exit() {
  rc=$?
  trap - EXIT ERR INT TERM HUP
  if (( rc != 0 && transition_started == 0 )); then restore_fence; fi
  if (( terminal == 0 )); then write_status "guardian_failed:unexpected_exit_$rc"; fi
  exit "$rc"
}
trap on_exit EXIT
trap 'terminal_status guardian_failed:signal; exit 1' INT TERM HUP
need() { [[ -s $state/$1 ]] || fail "missing_evidence_$1"; }
for item in candidate-image-id activation-live-image-id activation-container activation-container-id activation-candidate-image-id commit; do need "$item"; done
candidate=$(<"$state/candidate-image-id"); rollback_image=$(<"$state/activation-live-image-id")
[[ $candidate =~ ^sha256:[[:xdigit:]]{64}$ && $rollback_image =~ ^sha256:[[:xdigit:]]{64}$ ]] || fail invalid_immutable_image_evidence
[[ $(<"$state/activation-container") == "$container" ]] || fail canonical_container_mismatch
mkdir -p "$(dirname "$lock_path")" || fail lock_directory_unavailable
exec 9>"$lock_path"
flock -n 9 || { terminal_status lifecycle_lock_busy; exit 2; }
read_live() { docker inspect -f '{{.Id}}|{{.Image}}' "$container"; }
assert_cas() {
  local actual candidate_actual
  actual=$(read_live) || fail canonical_container_unavailable
  [[ $actual == "$(<"$state/activation-container-id")|$rollback_image" ]] || fail guardian_cas_live_target_changed
  candidate_actual=$(docker image inspect -f '{{.Id}}' "the-ai-crowd/moss-all-in-one:write-safe-root-$(<"$state/commit")") || fail guardian_cas_candidate_missing
  [[ $candidate_actual == "$candidate" && $(<"$state/activation-candidate-image-id") == "$candidate" ]] || fail guardian_cas_candidate_changed
}
health_idle() {
  docker exec "$container" sh -lc 'curl -fsS http://127.0.0.1:8787/health' |
    jq -e 'type == "object" and .status == "ok" and (.active_streams|type == "number") and (.active_runs|type == "number") and .active_streams == 0 and .active_runs == 0' >/dev/null
}
fence_ingress() {
  write_status fencing_ingress
  docker exec "$container" supervisorctl -c /etc/supervisor/conf.d/moss-all-in-one.conf stop moss-gateway >/dev/null || fail gateway_fence_failed
  # From this point cleanup must restore the gateway even if network fencing fails.
  fenced=1
  docker network disconnect "$ingress_network" "$container" || fail proxy_fence_failed
}
admit_after_fence() {
  health_idle || return 1
  sleep 5
  health_idle
}
wait_for_initial_idle() {
  local deadline=$((SECONDS + admission_wait_seconds))
  write_status waiting_for_idle
  while (( SECONDS <= deadline )); do
    if health_idle && sleep 5 && health_idle; then return 0; fi
    sleep 5
  done
  return 1
}
probe_ready() {
  local expected=$1 observed
  observed=$(docker inspect -f '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}|{{.Image}}' "$container")
  [[ $observed == "running|healthy|$expected" ]] || return 1
  docker exec "$container" sh -lc 'curl -fsS http://127.0.0.1:8787/health >/dev/null && curl -fsS http://127.0.0.1:8644/health >/dev/null && curl -fsS http://127.0.0.1:9119/ >/dev/null'
  curl -fsS -o /dev/null -w '%{http_code}' https://hermes.rodolflix.com/ | grep -Eq '^(200|401|403)$'
}
rollback() {
  # Persist an unambiguous recovery-required receipt before rollback mutates.
  write_status rollback_uncertain
  docker image tag "$rollback_image" "$production_image" || { terminal_status rollback_failed:retag; return 1; }
  "${compose[@]}" up -d --no-deps --force-recreate --wait --wait-timeout 180 "$service" || { terminal_status rollback_failed:compose; return 1; }
  fenced=0
  probe_ready "$rollback_image" || { terminal_status rollback_failed:readiness; return 1; }
  terminal_status rollback_ready
}
write_status guardian_started
# An observation happens before the fence only to avoid needless ingress loss.
# It is never admission: admission is exclusively the post-fence stable window.
if ! wait_for_initial_idle; then terminal_status admission_blocked:active_or_ambiguous; exit 2; fi
fence_ingress
if ! admit_after_fence; then terminal_status admission_blocked:post_fence_activity; exit 2; fi
assert_cas
printf '%s\n' "$rollback_image" >"$state/rollback-image"
# This receipt is deliberately durable before the first tag/Compose mutation: a
# non-trappable death cannot be mistaken for a completed or merely pending deploy.
write_status activation_uncertain
transition_started=1
docker image tag "$candidate" "$production_image" || { rollback; exit 1; }
if ! "${compose[@]}" up -d --no-deps --force-recreate --wait --wait-timeout 180 "$service"; then rollback; exit 1; fi
fenced=0
if ! probe_ready "$candidate"; then rollback; exit 1; fi
rm -f "$state/rollback-image"
terminal_status promote_complete
