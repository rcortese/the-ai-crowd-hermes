#!/bin/bash
set -euo pipefail

readonly IMAGE='sha256:c87824a7b47afa69e01631ac73f940022ba58447d6f22e068336f71fe19450fa'
readonly STACK='/mnt/user/appdata/the-ai-crowd'
readonly ROOT="$STACK/state/private/backups/runtime-preimages"
readonly SWEEPER="$STACK/ops/runtime-backup-retention.py"

[[ -d "$ROOT" && ! -L "$ROOT" ]] || { echo 'backup_root_missing_or_unsafe' >&2; exit 1; }
[[ -f "$SWEEPER" && ! -L "$SWEEPER" ]] || { echo 'sweeper_missing_or_unsafe' >&2; exit 1; }
[[ "$(docker image inspect "$IMAGE" --format '{{.Id}}')" == "$IMAGE" ]] || { echo 'retention_image_mismatch' >&2; exit 1; }

exec docker run --rm \
  --name runtime-backup-retention \
  --network none \
  --read-only \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --user 99:100 \
  --tmpfs /tmp:rw,nosuid,noexec,size=16m \
  --mount "type=bind,src=$ROOT,dst=/backup" \
  --mount "type=bind,src=$SWEEPER,dst=/opt/runtime-backup-retention.py,readonly" \
  --entrypoint /opt/hermes/.venv/bin/python \
  "$IMAGE" /opt/runtime-backup-retention.py --root /backup
