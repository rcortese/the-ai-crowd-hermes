#!/bin/bash
set -euo pipefail

readonly STACK_ROOT="${STACK_ROOT:-/mnt/user/appdata/the-ai-crowd}"
readonly USER_SCRIPTS_ROOT="${USER_SCRIPTS_ROOT:-/boot/config/plugins/user.scripts}"
readonly RUNTIME_SCHEDULE="${RUNTIME_SCHEDULE:-/tmp/user.scripts/schedule.json}"
readonly DAILY_RUNNER="${DAILY_RUNNER:-/etc/cron.daily/user.script.start.daily.sh}"
readonly UPDATE_CRON="${UPDATE_CRON:-/usr/local/sbin/update_cron}"
readonly PREIMAGE_ROOT="${1:?usage: install-runtime-backup-retention.sh PREIMAGE_ROOT}"
readonly SOURCE_WRAPPER="$STACK_ROOT/ops/runtime-backup-retention-wrapper.sh"
readonly DEST_DIR="$USER_SCRIPTS_ROOT/scripts/runtime_backup_retention"
readonly DEST_SCRIPT="$DEST_DIR/script"
readonly DEST_NAME="$DEST_DIR/name"
readonly SCHEDULE="$USER_SCRIPTS_ROOT/schedule.json"
readonly SCRIPT_KEY="$DEST_SCRIPT"
readonly PREIMAGE_DIR="$PREIMAGE_ROOT/scheduler"

[[ -d "$PREIMAGE_ROOT" && ! -L "$PREIMAGE_ROOT" ]] || { echo 'preimage_root_missing_or_unsafe' >&2; exit 1; }
[[ -f "$SOURCE_WRAPPER" && ! -L "$SOURCE_WRAPPER" ]] || { echo 'source_wrapper_missing_or_unsafe' >&2; exit 1; }
[[ -x "$DAILY_RUNNER" && -x "$UPDATE_CRON" ]] || { echo 'scheduler_runtime_missing' >&2; exit 1; }
[[ ! -L "$USER_SCRIPTS_ROOT" && ! -L "$DEST_DIR" && ! -L "$DEST_SCRIPT" && ! -L "$DEST_NAME" && ! -L "$SCHEDULE" && ! -L "$RUNTIME_SCHEDULE" ]] || { echo 'scheduler_destination_symlink_rejected' >&2; exit 1; }

mkdir -m 0700 "$PREIMAGE_DIR"
state_file="$PREIMAGE_DIR/state.json"
receipt_file="$PREIMAGE_DIR/install-receipt.json"
records="$PREIMAGE_DIR/records.tsv"
: > "$records"; chmod 0600 "$records"
dest_dir_existed=false; [[ -d "$DEST_DIR" ]] && dest_dir_existed=true

snapshot_file() {
  local label="$1" target="$2" mode hash size
  if [[ -e "$target" ]]; then
    [[ -f "$target" && ! -L "$target" ]] || { echo "unsafe_preimage_target:$label" >&2; exit 1; }
    mode=$(stat -c %a "$target"); hash=$(sha256sum "$target" | cut -d' ' -f1); size=$(stat -c %s "$target")
    install -m 0600 "$target" "$PREIMAGE_DIR/$label"
    printf '%s\tpresent\t%s\t%s\t%s\t%s\n' "$label" "$target" "$mode" "$hash" "$size" >> "$records"
  else
    printf '%s\tabsent\t%s\t-\t-\t-\n' "$label" "$target" >> "$records"
  fi
}

snapshot_file script "$DEST_SCRIPT"
snapshot_file name "$DEST_NAME"
snapshot_file schedule "$SCHEDULE"
snapshot_file runtime-schedule "$RUNTIME_SCHEDULE"
jq -Rn --argjson dest_dir_existed "$dest_dir_existed" '[inputs|split("\t")|{label:.[0],state:.[1],target:.[2],mode:.[3],sha256:.[4],bytes:.[5]}] | {schema_version:1,dest_dir_existed:$dest_dir_existed,files:.}' < "$records" > "$state_file"
chmod 0600 "$state_file"; sync -f "$PREIMAGE_DIR"; sync -f "$PREIMAGE_ROOT"

mutated=0
restoring=0
tmp_script=''; tmp_name=''; tmp_schedule=''; tmp_runtime=''
restore_preimage() {
  restoring=1
  local row label state target mode tmp
  while IFS=$'\t' read -r label state target mode _; do
    [[ ! -L "$target" ]] || return 1
    if [[ "$state" == present ]]; then
      mkdir -p "$(dirname "$target")"
      tmp=$(mktemp "$(dirname "$target")/.restore.XXXXXX")
      install -m "$mode" "$PREIMAGE_DIR/$label" "$tmp"
      mv -f "$tmp" "$target"
      sync -f "$target"
    else
      rm -f -- "$target"
    fi
  done < "$records"
  if [[ "$dest_dir_existed" == false ]]; then rmdir "$DEST_DIR" 2>/dev/null || true; fi
  "$UPDATE_CRON"
  sync -f "$USER_SCRIPTS_ROOT"
}
on_exit() {
  local rc=$?
  rm -f -- "$tmp_script" "$tmp_name" "$tmp_schedule" "$tmp_runtime"
  if (( rc != 0 && mutated == 1 && restoring == 0 )); then
    if ! restore_preimage; then
      echo 'SCHEDULER_RESTORATION_UNRESOLVED' >&2
      exit 70
    fi
    echo 'SCHEDULER_RESTORED_AFTER_FAILURE' >&2
  fi
  exit "$rc"
}
trap on_exit EXIT

mkdir -p "$DEST_DIR" "$(dirname "$RUNTIME_SCHEDULE")"
tmp_script=$(mktemp "$DEST_DIR/.script.XXXXXX")
tmp_name=$(mktemp "$DEST_DIR/.name.XXXXXX")
tmp_schedule=$(mktemp "$USER_SCRIPTS_ROOT/.schedule.XXXXXX")
tmp_runtime=$(mktemp "$(dirname "$RUNTIME_SCHEDULE")/.schedule.XXXXXX")
install -m 0755 "$SOURCE_WRAPPER" "$tmp_script"
printf '%s\n' 'runtime_backup_retention' > "$tmp_name"; chmod 0644 "$tmp_name"
if [[ -f "$SCHEDULE" ]]; then
  jq --arg key "$SCRIPT_KEY" '. + {($key): {script:$key,frequency:"daily",id:("schedule"+($key|@base64)),custom:""}}' "$SCHEDULE" > "$tmp_schedule"
else
  jq -n --arg key "$SCRIPT_KEY" '{($key): {script:$key,frequency:"daily",id:("schedule"+($key|@base64)),custom:""}}' > "$tmp_schedule"
fi
jq -e --arg key "$SCRIPT_KEY" '.[$key].script==$key and .[$key].frequency=="daily" and .[$key].custom==""' "$tmp_schedule" >/dev/null
install -m 0644 "$tmp_schedule" "$tmp_runtime"
mutated=1
mv -f "$tmp_script" "$DEST_SCRIPT"; tmp_script=''
mv -f "$tmp_name" "$DEST_NAME"; tmp_name=''
mv -f "$tmp_schedule" "$SCHEDULE"; tmp_schedule=''
mv -f "$tmp_runtime" "$RUNTIME_SCHEDULE"; tmp_runtime=''
sync -f "$DEST_SCRIPT"; sync -f "$DEST_NAME"; sync -f "$SCHEDULE"; sync -f "$RUNTIME_SCHEDULE"; sync -f "$DEST_DIR"; sync -f "$USER_SCRIPTS_ROOT"
if [[ "${ALLOW_TEST_FAILPOINT:-0}" == 1 && "${INSTALL_FAILPOINT:-}" == after_schedule ]]; then false; fi
"$UPDATE_CRON"
cmp -s "$SCHEDULE" "$RUNTIME_SCHEDULE"
jq -e --arg key "$SCRIPT_KEY" '.[$key].script==$key and .[$key].frequency=="daily" and .[$key].custom==""' "$SCHEDULE" >/dev/null
[[ -x "$DEST_SCRIPT" && "$(sha256sum "$DEST_SCRIPT" | cut -d' ' -f1)" == "$(sha256sum "$SOURCE_WRAPPER" | cut -d' ' -f1)" ]]
jq -n --arg script_sha "$(sha256sum "$DEST_SCRIPT"|cut -d' ' -f1)" --arg schedule_sha "$(sha256sum "$SCHEDULE"|cut -d' ' -f1)" --arg runtime_schedule_sha "$(sha256sum "$RUNTIME_SCHEDULE"|cut -d' ' -f1)" '{schema_version:1,status:"installed",script_sha256:$script_sha,schedule_sha256:$schedule_sha,runtime_schedule_sha256:$runtime_schedule_sha}' > "$receipt_file"
chmod 0600 "$receipt_file"; sync -f "$receipt_file"; sync -f "$PREIMAGE_DIR"
mutated=0
echo 'RETENTION_SCHEDULER=INSTALLED'
