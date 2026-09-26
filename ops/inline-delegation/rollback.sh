#!/usr/bin/env bash
# Operator-triggered reversal after activation; host-side only.
set -euo pipefail
[[ "${1:-}" == 'approved-rollback' ]] || exit 2
HERE="$(cd "$(dirname "$0")" && pwd -P)"
STACK=/mnt/ssd/appdata/the-ai-crowd
exec 9>"$HERE/activation.lock"
flock -n 9 || exit 3
[[ "$(sha256sum "$STACK/compose.yaml" | cut -d' ' -f1)" == d06cc789f262260598f44341f2e1de5f6b413c6d722b7382a403c70a5e0fa95f ]] || exit 4
[[ "$(docker inspect the-ai-crowd-moss-1 --format '{{.Image}}')" == sha256:14a0a1930c386a9342efae4db712d3dcd39a9c4298709dcc3e0b39863a612f30 ]] || exit 5
cd "$STACK"
docker compose -f "$STACK/compose.yaml" -f "$HERE/compose.override.yaml" -f "$HERE/rollback.override.yaml" up -d --no-deps --no-build moss
for i in $(seq 1 45); do
  if [[ "$(docker inspect the-ai-crowd-moss-1 --format '{{.Image}} {{.State.Health.Status}}' 2>/dev/null || true)" == 'sha256:05838ef5c373b913f4a0652ca76f4f0ca827c6a18754b2616a39a6d02a9df005 healthy' ]]; then
    printf 'ROLLED_BACK_HEALTHY\n' > "$HERE/activation.state"
    exit 0
  fi
  sleep 2
done
printf 'rollback health failed\n' >&2
exit 1
