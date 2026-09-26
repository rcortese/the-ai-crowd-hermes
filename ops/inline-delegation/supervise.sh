#!/usr/bin/env bash
# Detached host supervisor; survives replacement of the initiating Moss container.
set -u
[[ "${1:-}" == 'approved-supervise' ]] || exit 2
HERE="$(cd "$(dirname "$0")" && pwd -P)"
STACK=/mnt/ssd/appdata/the-ai-crowd
BASE=sha256:05838ef5c373b913f4a0652ca76f4f0ca827c6a18754b2616a39a6d02a9df005
NEXT=sha256:14a0a1930c386a9342efae4db712d3dcd39a9c4298709dcc3e0b39863a612f30
printf 'SUPERVISING pid=%s\n' "$$" > "$HERE/launcher.state"
# Fixed maximum bounds the host-side worker; abrupt worker death is reconciled.
timeout --signal=TERM --kill-after=5s 240s bash "$HERE/activate.sh" approved-activate
rc=$?
if [[ "$rc" == 0 && "$(docker inspect the-ai-crowd-moss-1 --format '{{.Image}} {{.State.Health.Status}}' 2>/dev/null || true)" == "$NEXT healthy" &&
      "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["state"])' "$HERE/source-receipt.json" 2>/dev/null || true)" == SOURCE_PUBLISHED ]]; then
  printf 'ACTIVE_HEALTHY pid=%s\n' "$$" > "$HERE/launcher.state"
  exit 0
fi
current="$(docker inspect the-ai-crowd-moss-1 --format '{{.Image}} {{.State.Health.Status}}' 2>/dev/null || true)"
if [[ "$current" == "$BASE healthy" ]]; then
  if bash "$HERE/rollback.sh" approved-rollback; then
    printf 'ROLLED_BACK_HEALTHY worker_rc=%s\n' "$rc" > "$HERE/launcher.state"
    exit 1
  fi
fi
# Guard against unrelated concurrent changes. If the worker died after the
# replacement, roll back only a recognized candidate state, not an unknown image.
if [[ "$current" == "$NEXT "* ]]; then
  if bash "$HERE/rollback.sh" approved-rollback; then
    printf 'ROLLED_BACK_HEALTHY worker_rc=%s\n' "$rc" > "$HERE/launcher.state"
    exit 1
  fi
fi
printf 'RECOVERY_REQUIRED worker_rc=%s state=%s\n' "$rc" "${current:-missing}" > "$HERE/launcher.state"
exit 1
