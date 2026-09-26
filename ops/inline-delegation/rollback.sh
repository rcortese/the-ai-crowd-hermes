#!/usr/bin/env bash
# Recovery of an UNPUBLISHED interrupted cutover only. Never rewinds published main.
set -euo pipefail
[[ "${1:-}" == 'approved-rollback' ]] || exit 2
HERE="$(cd "$(dirname "$0")" && pwd -P)"
STACK=/mnt/ssd/appdata/the-ai-crowd
BASE=sha256:05838ef5c373b913f4a0652ca76f4f0ca827c6a18754b2616a39a6d02a9df005
NEXT=sha256:14a0a1930c386a9342efae4db712d3dcd39a9c4298709dcc3e0b39863a612f30
OLD=de1afd1e65541ef7b358f86ef5ce488399b86937
exec 9>"$HERE/activation.lock"
flock -n 9 || exit 3
remote="$(git -c safe.directory="$STACK" -C "$STACK" ls-remote origin refs/heads/main)"
[[ "${remote%%[[:space:]]*}" == "$OLD" ]] || { printf 'published or unknown source: do not rewind\n' >&2; exit 4; }
current="$(docker inspect the-ai-crowd-moss-1 --format '{{.Image}} {{.State.Health.Status}}' 2>/dev/null || true)"
if [[ "$current" == "$NEXT "* ]]; then
  cd "$STACK"
  docker compose -f "$STACK/compose.yaml" -f "$HERE/compose.override.yaml" -f "$HERE/rollback.override.yaml" up -d --no-deps --no-build moss
  for i in $(seq 1 45); do
    current="$(docker inspect the-ai-crowd-moss-1 --format '{{.Image}} {{.State.Health.Status}}' 2>/dev/null || true)"
    [[ "$current" == "$BASE healthy" ]] && break
    sleep 2
  done
fi
[[ "$current" == "$BASE healthy" ]] || { printf 'runtime recovery required\n' >&2; exit 5; }
python3 "$HERE/source_transition.py" rollback
printf 'ROLLED_BACK_HEALTHY\n' > "$HERE/activation.state"
