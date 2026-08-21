#!/bin/bash
set -euo pipefail

readonly STACK_ROOT="${STACK_ROOT:-/mnt/user/appdata/the-ai-crowd}"
readonly STACK_ROOT_CANONICAL="${STACK_ROOT_CANONICAL:-$STACK_ROOT}"
readonly USER_SCRIPTS_ROOT="${USER_SCRIPTS_ROOT:-/boot/config/plugins/user.scripts}"
readonly RUNTIME_SCHEDULE_LOGICAL="${RUNTIME_SCHEDULE:-/tmp/user.scripts/schedule.json}"
readonly DAILY_RUNNER="${DAILY_RUNNER:-/etc/cron.daily/user.script.start.daily.sh}"

readonly PREIMAGE_ROOT="${1:?usage: install-runtime-backup-retention.sh PREIMAGE_ROOT}"
readonly PREIMAGE_ROOT_CANONICAL="${PREIMAGE_ROOT_CANONICAL:-$PREIMAGE_ROOT}"

assert_safe_chain() {
  local path="$1" current=''
  [[ "$path" == /* ]] || { echo "non_absolute_path:$path" >&2; return 1; }
  IFS='/' read -r -a parts <<< "${path#/}"
  for part in "${parts[@]}"; do
    [[ -n "$part" ]] || continue
    current="$current/$part"
    [[ ! -L "$current" ]] || { echo "symlink_ancestor_rejected:$current" >&2; return 1; }
    [[ -e "$current" ]] || break
  done
}
assert_safe_chain "$STACK_ROOT_CANONICAL"; assert_safe_chain "$USER_SCRIPTS_ROOT"; assert_safe_chain "$RUNTIME_SCHEDULE_LOGICAL"
[[ -d "$STACK_ROOT" && -d "$STACK_ROOT_CANONICAL" && -d "$USER_SCRIPTS_ROOT" && -d "$PREIMAGE_ROOT" ]] || { echo 'required_root_missing' >&2; exit 1; }
[[ "$STACK_ROOT_CANONICAL" == "$(readlink -f "$STACK_ROOT_CANONICAL")" ]] || { echo 'canonical_stack_root_not_canonical' >&2; exit 1; }
[[ "$(readlink -f "$STACK_ROOT")" == "$STACK_ROOT_CANONICAL" ]] || { echo 'stack_root_canonical_mismatch' >&2; exit 1; }
[[ "$(stat -Lc '%d:%i' "$STACK_ROOT")" == "$(stat -Lc '%d:%i' "$STACK_ROOT_CANONICAL")" ]] || { echo 'stack_root_identity_mismatch' >&2; exit 1; }
assert_safe_chain "$PREIMAGE_ROOT_CANONICAL"
[[ -d "$PREIMAGE_ROOT_CANONICAL" ]] || { echo 'canonical_preimage_root_missing' >&2; exit 1; }
[[ "$PREIMAGE_ROOT_CANONICAL" == "$(readlink -f "$PREIMAGE_ROOT_CANONICAL")" ]] || { echo 'canonical_preimage_root_not_canonical' >&2; exit 1; }
[[ "$(readlink -f "$PREIMAGE_ROOT")" == "$PREIMAGE_ROOT_CANONICAL" ]] || { echo 'preimage_canonical_mismatch' >&2; exit 1; }
[[ "$(stat -Lc '%d:%i' "$PREIMAGE_ROOT")" == "$(stat -Lc '%d:%i' "$PREIMAGE_ROOT_CANONICAL")" ]] || { echo 'preimage_identity_mismatch' >&2; exit 1; }
runtime_parent_logical=$(dirname "$RUNTIME_SCHEDULE_LOGICAL")
[[ -d "$runtime_parent_logical" ]] || { echo 'runtime_schedule_parent_missing' >&2; exit 1; }
exec {stack_fd}<"$STACK_ROOT_CANONICAL"; exec {user_fd}<"$USER_SCRIPTS_ROOT"; exec {runtime_fd}<"$runtime_parent_logical"; exec {preimage_fd}<"$PREIMAGE_ROOT_CANONICAL"
readonly STACK_ANCHOR="/proc/$$/fd/$stack_fd"
readonly USER_ANCHOR="/proc/$$/fd/$user_fd"
readonly RUNTIME_ANCHOR="/proc/$$/fd/$runtime_fd"
readonly PREIMAGE_ANCHOR="/proc/$$/fd/$preimage_fd"
[[ "$(stat -Lc '%d:%i' "$STACK_ROOT")" == "$(stat -Lc '%d:%i' "$STACK_ANCHOR")" ]]
[[ "$(stat -Lc '%d:%i' "$USER_SCRIPTS_ROOT")" == "$(stat -Lc '%d:%i' "$USER_ANCHOR")" ]]
[[ "$(stat -Lc '%d:%i' "$PREIMAGE_ROOT")" == "$(stat -Lc '%d:%i' "$PREIMAGE_ANCHOR")" ]]

[[ -d "$STACK_ANCHOR/ops" && ! -L "$STACK_ANCHOR/ops" ]] || { echo 'ops_parent_missing_or_unsafe' >&2; exit 1; }
exec {ops_fd}<"$STACK_ANCHOR/ops"
readonly OPS_ANCHOR="/proc/$$/fd/$ops_fd"
[[ ! -L "$STACK_ANCHOR/ops" && "$(stat -Lc '%d:%i' "$STACK_ANCHOR/ops")" == "$(stat -Lc '%d:%i' "$OPS_ANCHOR")" ]]
[[ -d "$USER_ANCHOR/scripts" && ! -L "$USER_ANCHOR/scripts" ]] || { echo 'scripts_parent_missing_or_unsafe' >&2; exit 1; }
exec {scripts_fd}<"$USER_ANCHOR/scripts"
readonly SCRIPTS_ANCHOR="/proc/$$/fd/$scripts_fd"
[[ ! -L "$USER_ANCHOR/scripts" && "$(stat -Lc '%d:%i' "$USER_ANCHOR/scripts")" == "$(stat -Lc '%d:%i' "$SCRIPTS_ANCHOR")" ]]
if [[ "${ALLOW_TEST_RACE_HOOK:-0}" == 1 ]]; then
 : "${TEST_RACE_DIR:?TEST_RACE_DIR required}"
 : > "$TEST_RACE_DIR/scripts-opened"
 while [[ ! -e "$TEST_RACE_DIR/continue" ]]; do sleep 0.01; done
fi

readonly SOURCE_WRAPPER="$OPS_ANCHOR/runtime-backup-retention-wrapper.sh"
readonly SOURCE_WRAPPER_SHA256='79533139747afd499faca69157c074a5987b929937a9ee72d263986ebded3e71'
readonly DEST_PARENT="$SCRIPTS_ANCHOR"
readonly DEST_DIR="$DEST_PARENT/runtime_backup_retention"
readonly SCHEDULE="$USER_ANCHOR/schedule.json"
readonly RUNTIME_SCHEDULE="$RUNTIME_ANCHOR/$(basename "$RUNTIME_SCHEDULE_LOGICAL")"
readonly SCRIPT_KEY="$USER_SCRIPTS_ROOT/scripts/runtime_backup_retention/script"
[[ -f "$SOURCE_WRAPPER" && ! -L "$SOURCE_WRAPPER" ]] || { echo 'source_wrapper_missing_or_unsafe' >&2; exit 1; }
exec {source_wrapper_fd}<"$SOURCE_WRAPPER"
readonly SOURCE_WRAPPER_ANCHOR="/proc/$$/fd/$source_wrapper_fd"
[[ "$(stat -Lc '%F' "$SOURCE_WRAPPER_ANCHOR")" == 'regular file' ]] || { echo 'source_wrapper_not_regular' >&2; exit 1; }
[[ ! -L "$SOURCE_WRAPPER" && "$(stat -Lc '%d:%i' "$SOURCE_WRAPPER")" == "$(stat -Lc '%d:%i' "$SOURCE_WRAPPER_ANCHOR")" ]] || { echo 'source_wrapper_identity_mismatch' >&2; exit 1; }
[[ "$(sha256sum "$SOURCE_WRAPPER_ANCHOR"|cut -d' ' -f1)" == "$SOURCE_WRAPPER_SHA256" ]] || { echo 'source_wrapper_hash_mismatch' >&2; exit 1; }
source_wrapper_identity_current() {
  [[ -f "$SOURCE_WRAPPER" && ! -L "$SOURCE_WRAPPER" ]] \
    && [[ "$(stat -Lc '%d:%i' "$SOURCE_WRAPPER")" == "$(stat -Lc '%d:%i' "$SOURCE_WRAPPER_ANCHOR")" ]]
}
if [[ "${ALLOW_TEST_SOURCE_RACE_HOOK:-0}" == 1 ]]; then
 : "${TEST_RACE_DIR:?TEST_RACE_DIR required}"
 : > "$TEST_RACE_DIR/source-wrapper-opened"
 while [[ ! -e "$TEST_RACE_DIR/continue" ]]; do sleep 0.01; done
fi
source_wrapper_identity_current || { echo 'source_wrapper_identity_changed' >&2; exit 1; }
[[ -x "$DAILY_RUNNER" ]] || { echo 'scheduler_runtime_missing' >&2; exit 1; }
[[ ! -L "$DEST_DIR" && ! -L "$SCHEDULE" && ! -L "$RUNTIME_SCHEDULE" ]] || { echo 'scheduler_destination_symlink_rejected' >&2; exit 1; }

dest_dir_existed=false; [[ -d "$DEST_DIR" ]] && dest_dir_existed=true
mkdir -m 0700 "$PREIMAGE_ANCHOR/scheduler"
exec {pre_sched_fd}<"$PREIMAGE_ANCHOR/scheduler"
readonly PREIMAGE_DIR="/proc/$$/fd/$pre_sched_fd"
[[ ! -L "$PREIMAGE_ANCHOR/scheduler" && "$(stat -Lc '%d:%i' "$PREIMAGE_ANCHOR/scheduler")" == "$(stat -Lc '%d:%i' "$PREIMAGE_DIR")" ]]
mkdir -p "$DEST_DIR"
exec {dest_fd}<"$DEST_DIR"
readonly DEST_ANCHOR="/proc/$$/fd/$dest_fd"
[[ ! -L "$DEST_DIR" && "$(stat -Lc '%d:%i' "$DEST_DIR")" == "$(stat -Lc '%d:%i' "$DEST_ANCHOR")" ]]
readonly DEST_SCRIPT="$DEST_ANCHOR/script"
readonly DEST_NAME="$DEST_ANCHOR/name"
[[ ! -L "$DEST_SCRIPT" && ! -L "$DEST_NAME" ]] || { echo 'scheduler_leaf_symlink_rejected' >&2; exit 1; }

state_file="$PREIMAGE_DIR/state.json"; receipt_file="$PREIMAGE_DIR/install-receipt.json"; records="$PREIMAGE_DIR/records.tsv"
: > "$records"; chmod 0600 "$records"
logical_target() { case "$1" in script) echo "$USER_SCRIPTS_ROOT/scripts/runtime_backup_retention/script";; name) echo "$USER_SCRIPTS_ROOT/scripts/runtime_backup_retention/name";; schedule) echo "$USER_SCRIPTS_ROOT/schedule.json";; runtime-schedule) echo "$RUNTIME_SCHEDULE_LOGICAL";; esac; }
anchored_target() { case "$1" in script) echo "$DEST_SCRIPT";; name) echo "$DEST_NAME";; schedule) echo "$SCHEDULE";; runtime-schedule) echo "$RUNTIME_SCHEDULE";; esac; }
snapshot_file() {
  local label="$1" target logical mode hash size
  target=$(anchored_target "$label"); logical=$(logical_target "$label")
  if [[ -e "$target" ]]; then
    [[ -f "$target" && ! -L "$target" ]] || { echo "unsafe_preimage_target:$label" >&2; exit 1; }
    mode=$(stat -c %a "$target"); hash=$(sha256sum "$target" | cut -d' ' -f1); size=$(stat -c %s "$target")
    install -m 0600 "$target" "$PREIMAGE_DIR/$label"
    printf '%s\tpresent\t%s\t%s\t%s\t%s\n' "$label" "$logical" "$mode" "$hash" "$size" >> "$records"
  else
    printf '%s\tabsent\t%s\t-\t-\t-\n' "$label" "$logical" >> "$records"
  fi
}
snapshot_file script; snapshot_file name; snapshot_file schedule; snapshot_file runtime-schedule
jq -Rn --argjson dest_dir_existed "$dest_dir_existed" '[inputs|split("\t")|{label:.[0],state:.[1],target:.[2],mode:.[3],sha256:.[4],bytes:.[5]}] | {schema_version:1,dest_dir_existed:$dest_dir_existed,files:.}' < "$records" > "$state_file"
chmod 0600 "$state_file"; sync -f "$PREIMAGE_DIR"; sync -f "$PREIMAGE_ANCHOR"

mutated=0; restoring=0; tmp_script=''; tmp_name=''; tmp_schedule=''; tmp_runtime=''
verify_preimages() {
  local label state _logical _mode expected_hash expected_size source
  while IFS=$'\t' read -r label state _logical _mode expected_hash expected_size; do
    [[ "$state" == present ]] || continue
    source="$PREIMAGE_DIR/$label"
    [[ -f "$source" && ! -L "$source" && "$(stat -c %a "$source")" == 600 ]] || return 1
    [[ "$(stat -c %s "$source")" == "$expected_size" ]] || return 1
    [[ "$(sha256sum "$source" | cut -d' ' -f1)" == "$expected_hash" ]] || return 1
  done < "$records"
}
restore_preimage() {
  restoring=1
  verify_preimages || return 1
  local label state _logical mode _hash _size target tmp
  while IFS=$'\t' read -r label state _logical mode _hash _size; do
    target=$(anchored_target "$label")
    [[ ! -L "$target" ]] || return 1
    if [[ "$state" == present ]]; then
      tmp=$(mktemp "$(dirname "$target")/.restore.XXXXXX")
      install -m "$mode" "$PREIMAGE_DIR/$label" "$tmp"; mv -f "$tmp" "$target"; sync -f "$target"
    else
      rm -f -- "$target"
    fi
  done < "$records"
  if [[ "$dest_dir_existed" == false ]]; then rmdir "$DEST_DIR"; fi
  sync -f "$USER_ANCHOR"
}
on_exit() {
  local rc=$?
  rm -f -- "$tmp_script" "$tmp_name" "$tmp_schedule" "$tmp_runtime"
  if (( rc != 0 && mutated == 1 && restoring == 0 )); then
    if ! restore_preimage; then echo 'SCHEDULER_RESTORATION_UNRESOLVED' >&2; exit 70; fi
    echo 'SCHEDULER_RESTORED_AFTER_FAILURE' >&2
  fi
  exit "$rc"
}
trap on_exit EXIT

tmp_script=$(mktemp "$DEST_ANCHOR/.script.XXXXXX"); tmp_name=$(mktemp "$DEST_ANCHOR/.name.XXXXXX")
tmp_schedule=$(mktemp "$USER_ANCHOR/.schedule.XXXXXX"); tmp_runtime=$(mktemp "$RUNTIME_ANCHOR/.schedule.XXXXXX")
install -m 0755 "$SOURCE_WRAPPER_ANCHOR" "$tmp_script"; [[ "$(sha256sum "$tmp_script"|cut -d' ' -f1)" == "$SOURCE_WRAPPER_SHA256" ]]; printf '%s\n' runtime_backup_retention > "$tmp_name"; chmod 0644 "$tmp_name"
if [[ -f "$SCHEDULE" ]]; then jq --arg key "$SCRIPT_KEY" '. + {($key): {script:$key,frequency:"daily",id:("schedule"+($key|@base64)),custom:""}}' "$SCHEDULE" > "$tmp_schedule"; else jq -n --arg key "$SCRIPT_KEY" '{($key): {script:$key,frequency:"daily",id:("schedule"+($key|@base64)),custom:""}}' > "$tmp_schedule"; fi
jq -e --arg key "$SCRIPT_KEY" '.[$key].script==$key and .[$key].frequency=="daily" and .[$key].custom==""' "$tmp_schedule" >/dev/null
install -m 0644 "$tmp_schedule" "$tmp_runtime"
mutated=1
mv -f "$tmp_script" "$DEST_SCRIPT"; tmp_script=''; mv -f "$tmp_name" "$DEST_NAME"; tmp_name=''; mv -f "$tmp_schedule" "$SCHEDULE"; tmp_schedule=''; mv -f "$tmp_runtime" "$RUNTIME_SCHEDULE"; tmp_runtime=''
sync -f "$DEST_SCRIPT"; sync -f "$DEST_NAME"; sync -f "$SCHEDULE"; sync -f "$RUNTIME_SCHEDULE"; sync -f "$DEST_ANCHOR"; sync -f "$USER_ANCHOR"
if [[ "${ALLOW_TEST_FAILPOINT:-0}" == 1 && "${INSTALL_FAILPOINT:-}" == after_schedule ]]; then
  if [[ -n "${INSTALL_CORRUPT_PREIMAGE_LABEL:-}" ]]; then printf 'corrupt' > "$PREIMAGE_DIR/$INSTALL_CORRUPT_PREIMAGE_LABEL"; fi
  false
fi
[[ ! -L "$USER_ANCHOR/scripts" && "$(stat -Lc '%d:%i' "$USER_ANCHOR/scripts")" == "$(stat -Lc '%d:%i' "$SCRIPTS_ANCHOR")" ]] || { echo 'scripts_parent_identity_changed' >&2; false; }
source_wrapper_identity_current || { echo 'source_wrapper_identity_changed' >&2; false; }
cmp -s "$SCHEDULE" "$RUNTIME_SCHEDULE"
jq -e --arg key "$SCRIPT_KEY" '.[$key].script==$key and .[$key].frequency=="daily" and .[$key].custom==""' "$SCHEDULE" >/dev/null
dest_script_mode=$(stat -c %a "$DEST_SCRIPT")
[[ -f "$DEST_SCRIPT" && ! -L "$DEST_SCRIPT" && ( "$dest_script_mode" == 600 || "$dest_script_mode" == 755 ) && "$(sha256sum "$DEST_SCRIPT"|cut -d' ' -f1)" == "$SOURCE_WRAPPER_SHA256" ]]
source_wrapper_identity_current || { echo 'source_wrapper_identity_changed' >&2; false; }
jq -n --arg script_sha "$(sha256sum "$DEST_SCRIPT"|cut -d' ' -f1)" --arg schedule_sha "$(sha256sum "$SCHEDULE"|cut -d' ' -f1)" --arg runtime_schedule_sha "$(sha256sum "$RUNTIME_SCHEDULE"|cut -d' ' -f1)" '{schema_version:1,status:"installed",script_sha256:$script_sha,schedule_sha256:$schedule_sha,runtime_schedule_sha256:$runtime_schedule_sha}' > "$receipt_file"
chmod 0600 "$receipt_file"; sync -f "$receipt_file"; sync -f "$PREIMAGE_DIR"; mutated=0
echo 'RETENTION_SCHEDULER=INSTALLED'
