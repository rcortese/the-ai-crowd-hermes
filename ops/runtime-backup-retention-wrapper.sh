#!/bin/bash
set -euo pipefail

readonly IMAGE='sha256:358d555feed07110e4c039973daad70ab27950e7a3b472c1b663f497059dd4be'
readonly STACK="${STACK_ROOT:-/mnt/user/appdata/the-ai-crowd}"
readonly ROOT="$STACK/state/private/backups/runtime-preimages"
readonly SWEEPER="$STACK/ops/runtime-backup-retention.py"
readonly SWEEPER_SHA256='7f7926dc6bd77f6fb1eda321f5662ab5349a3924a531de3b55d466e7fbf8105b'

[[ -d "$ROOT" && ! -L "$ROOT" ]] || { echo 'backup_root_missing_or_unsafe' >&2; exit 1; }
[[ -f "$SWEEPER" && ! -L "$SWEEPER" ]] || { echo 'sweeper_missing_or_unsafe' >&2; exit 1; }
[[ "$(docker image inspect "$IMAGE" --format '{{.Id}}')" == "$IMAGE" ]] || { echo 'retention_image_mismatch' >&2; exit 1; }
exec {sweeper_fd}<"$SWEEPER"
[[ "$(stat -Lc '%F' "/proc/$$/fd/$sweeper_fd")" == 'regular file' ]] || { echo 'sweeper_not_regular' >&2; exit 1; }
readonly SNAPSHOT="$(mktemp /tmp/runtime-backup-retention.XXXXXX.py)"
cleanup() { rm -f -- "$SNAPSHOT"; }
trap cleanup EXIT
cp "/proc/$$/fd/$sweeper_fd" "$SNAPSHOT"
chmod 0444 "$SNAPSHOT"
[[ "$(sha256sum "/proc/$$/fd/$sweeper_fd" | cut -d' ' -f1)" == "$SWEEPER_SHA256" ]] || { echo 'sweeper_source_hash_mismatch' >&2; exit 1; }
[[ "$(sha256sum "$SNAPSHOT" | cut -d' ' -f1)" == "$SWEEPER_SHA256" ]] || { echo 'sweeper_snapshot_hash_mismatch' >&2; exit 1; }

container_name="runtime-backup-retention-$$"
docker run --rm \
  --name "$container_name" \
  --network none \
  --read-only \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --user 99:100 \
  --tmpfs /tmp:rw,nosuid,noexec,size=16m \
  --mount "type=bind,src=$ROOT,dst=/backup" \
  --mount "type=bind,src=$SNAPSHOT,dst=/opt/runtime-backup-retention.py,readonly" \
  --entrypoint /opt/hermes/.venv/bin/python \
  "$IMAGE" /opt/runtime-backup-retention.py --root /backup
