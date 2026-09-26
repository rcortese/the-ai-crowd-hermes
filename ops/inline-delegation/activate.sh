#!/usr/bin/env bash
# Run ONLY on the Docker host after Rodolfo's explicit OK. Never run inside Moss.
set -euo pipefail
[[ "${1:-}" == 'approved-activate' ]] || { printf 'requires approved-activate\n' >&2; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd -P)"
STACK=/mnt/ssd/appdata/the-ai-crowd
CONTAINER=the-ai-crowd-moss-1
NEXT=sha256:14a0a1930c386a9342efae4db712d3dcd39a9c4298709dcc3e0b39863a612f30
BASE=sha256:05838ef5c373b913f4a0652ca76f4f0ca827c6a18754b2616a39a6d02a9df005
exec 9>"$HERE/activation.lock"
flock -n 9 || { printf 'activation already locked\n' >&2; exit 3; }
cd "$STACK"
state="$HERE/activation.state"
printf 'PREFLIGHT\n' > "$state"
python3 "$HERE/preflight.py"
compose=(docker compose -f "$STACK/compose.yaml" -f "$HERE/compose.override.yaml")
restore=0
rollback() {
  rc=$?
  if [[ "$restore" == 1 ]]; then
    if [[ ! -f "$HERE/source-receipt.json" ]]; then
      printf 'PREFLIGHT_FAILED_NO_SOURCE_EFFECT\n' > "$state"
      exit "$rc"
    fi
    # Publication may have succeeded even if its acknowledgement was lost.
    # Never rewind published source or roll runtime behind it blindly.
    remote="$(git -c safe.directory="$STACK" -C "$STACK" ls-remote origin refs/heads/main 2>/dev/null || true)"
    if [[ -z "$remote" ]]; then
      printf 'RECOVERY_REQUIRED_REMOTE_UNKNOWN\n' > "$state"
      exit "$rc"
    fi
    if [[ "${remote%%[[:space:]]*}" != de1afd1e65541ef7b358f86ef5ce488399b86937 ]]; then
      printf 'RECOVERY_REQUIRED_REMOTE_NOT_OLD\n' > "$state"
      exit "$rc"
    fi
    printf 'ROLLBACK_ATTEMPT\n' > "$state"
    current="$(docker inspect "$CONTAINER" --format '{{.Image}} {{.State.Health.Status}}' 2>/dev/null || true)"
    if [[ "$current" != "$BASE healthy" ]]; then
      if [[ "$current" != "$NEXT "* ]]; then
        printf 'RECOVERY_REQUIRED_UNKNOWN_CONTAINER\n' > "$state"
        exit "$rc"
      fi
      if "${compose[@]}" -f "$HERE/rollback.override.yaml" up -d --no-deps --no-build moss; then
        printf 'ROLLBACK_STARTED\n' > "$state"
        for i in $(seq 1 45); do
          [[ "$(docker inspect "$CONTAINER" --format '{{.Image}} {{.State.Health.Status}}' 2>/dev/null || true)" == "$BASE healthy" ]] && break
          sleep 2
        done
      else
        printf 'ROLLBACK_FAILED\n' > "$state"
      fi
    fi
    if [[ "$(docker inspect "$CONTAINER" --format '{{.Image}} {{.State.Health.Status}}' 2>/dev/null || true)" == "$BASE healthy" ]]; then
      if python3 "$HERE/source_transition.py" rollback; then
        printf 'ROLLED_BACK_HEALTHY\n' > "$state"
      else
        printf 'SOURCE_ROLLBACK_FAILED\n' > "$state"
      fi
    fi
  fi
  exit "$rc"
}
trap rollback EXIT
printf 'ACTIVATING\n' > "$state"
restore=1
python3 "$HERE/source_transition.py" prepare
docker compose -f "$STACK/compose.yaml" up -d --no-deps --no-build moss
for i in $(seq 1 45); do
  if [[ "$(docker inspect "$CONTAINER" --format '{{.Image}} {{.State.Health.Status}}' 2>/dev/null || true)" == "$NEXT healthy" ]]; then
    docker exec "$CONTAINER" curl -fsS http://127.0.0.1:8787/health >/dev/null
    docker exec "$CONTAINER" curl -fsS http://127.0.0.1:8648/health >/dev/null
    curl -fsS http://127.0.0.1:8644/health >/dev/null
    python3 "$HERE/source_transition.py" verify-runtime
    python3 "$HERE/source_transition.py" publish
    restore=0
    printf 'ACTIVE_HEALTHY %s\n' "$(docker inspect "$CONTAINER" --format '{{.Id}}')" > "$state"
    trap - EXIT
    exit 0
  fi
  sleep 2
done
printf 'candidate failed health; rolling back\n' >&2
exit 1
