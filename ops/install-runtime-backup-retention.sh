#!/bin/bash
set -euo pipefail

readonly STACK='/mnt/user/appdata/the-ai-crowd'
readonly SOURCE_WRAPPER="$STACK/ops/runtime-backup-retention-wrapper.sh"
readonly DEST_DIR='/boot/config/plugins/user.scripts/scripts/runtime_backup_retention'
readonly DEST_SCRIPT="$DEST_DIR/script"
readonly DEST_NAME="$DEST_DIR/name"
readonly SCHEDULE='/boot/config/plugins/user.scripts/schedule.json'
readonly RUNTIME_SCHEDULE='/tmp/user.scripts/schedule.json'
readonly DAILY_RUNNER='/etc/cron.daily/user.script.start.daily.sh'
readonly SCRIPT_KEY="$DEST_SCRIPT"

[[ -f "$SOURCE_WRAPPER" && ! -L "$SOURCE_WRAPPER" ]] || { echo 'source_wrapper_missing_or_unsafe' >&2; exit 1; }
[[ -x "$DAILY_RUNNER" ]] || { echo 'daily_runner_missing' >&2; exit 1; }
mkdir -p "$DEST_DIR"
[[ ! -L "$DEST_DIR" && ! -L "$DEST_SCRIPT" && ! -L "$DEST_NAME" && ! -L "$SCHEDULE" ]] || { echo 'scheduler_destination_symlink_rejected' >&2; exit 1; }

tmp_script=$(mktemp "$DEST_DIR/.script.XXXXXX")
tmp_name=$(mktemp "$DEST_DIR/.name.XXXXXX")
tmp_schedule=$(mktemp /boot/config/plugins/user.scripts/.schedule.XXXXXX)
trap 'rm -f "$tmp_script" "$tmp_name" "$tmp_schedule"' EXIT
install -m 0755 "$SOURCE_WRAPPER" "$tmp_script"
printf '%s\n' 'runtime_backup_retention' > "$tmp_name"
chmod 0644 "$tmp_name"
if [[ -f "$SCHEDULE" ]]; then
  jq --arg key "$SCRIPT_KEY" '. + {($key): {script:$key,frequency:"daily",id:"schedule"+($key|@base64),custom:""}}' "$SCHEDULE" > "$tmp_schedule"
else
  jq -n --arg key "$SCRIPT_KEY" '{($key): {script:$key,frequency:"daily",id:"schedule"+($key|@base64),custom:""}}' > "$tmp_schedule"
fi
jq -e --arg key "$SCRIPT_KEY" '.[$key].script==$key and .[$key].frequency=="daily" and .[$key].custom==""' "$tmp_schedule" >/dev/null
mv -f "$tmp_script" "$DEST_SCRIPT"
mv -f "$tmp_name" "$DEST_NAME"
mv -f "$tmp_schedule" "$SCHEDULE"
sync -f "$DEST_SCRIPT"; sync -f "$DEST_NAME"; sync -f "$SCHEDULE"; sync -f "$DEST_DIR"
install -m 0644 "$SCHEDULE" "$RUNTIME_SCHEDULE"
/usr/local/sbin/update_cron
cmp -s "$SCHEDULE" "$RUNTIME_SCHEDULE"
jq -e --arg key "$SCRIPT_KEY" '.[$key].script==$key and .[$key].frequency=="daily"' "$SCHEDULE" >/dev/null
[[ -x "$DEST_SCRIPT" && "$(sha256sum "$DEST_SCRIPT" | cut -d' ' -f1)" == "$(sha256sum "$SOURCE_WRAPPER" | cut -d' ' -f1)" ]]
echo 'RETENTION_SCHEDULER=INSTALLED'
