#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
readonly PROD_ROOT=/mnt/ssd/appdata/the-ai-crowd-hddt
readonly PROD_PARENT=/mnt/ssd/appdata
readonly CANONICAL_REMOTE=git@github.com:rcortese/the-ai-crowd-hermes.git
fail(){ printf 'HDDT bootstrap: %s\n' "$1" >&2; exit "${2:-65}"; }
sha(){ sha256sum -- "$1" | cut -d' ' -f1; }
git_at(){ GIT_OPTIONAL_LOCKS=0 "$git_bin" -c safe.directory="$1" -C "$1" "${@:2}"; }
validate_receipt(){
  local receipt_file=$1 executor=$2 launcher=$3 builder=$4
  [[ -f $receipt_file && ! -L $receipt_file && $(stat -c '%u:%g:%a' "$receipt_file") == 0:0:600 && $(sha "$receipt_file") == "$receipt_hash" ]] || fail 'receipt custody or bytes mismatch' 65
  jq -e --arg rev "$revision" --arg tree "$tree" --arg remote "$CANONICAL_REMOTE" --arg image "$candidate_image" --arg exec "$(sha "$executor")" --arg launcher "$(sha "$launcher")" --arg builder "$(sha "$builder")" '.source_revision==$rev and .source_tree==$tree and .source_remote==$remote and .candidate_image_id==$image and .executor_sha256==$exec and .launcher_sha256==$launcher and .builder_sha256==$builder' "$receipt_file" >/dev/null || fail 'receipt component binding mismatch' 65
}
validate_release_checkout(){
  local checkout=$1
  [[ -d $checkout && ! -L $checkout && $(stat -c '%u:%g:%a' "$checkout") == 0:0:700 ]] || fail 'release checkout custody invalid' 65
  [[ $(git_at "$checkout" rev-parse HEAD) == "$revision" && $(git_at "$checkout" rev-parse 'HEAD^{tree}') == "$tree" && $(git_at "$checkout" remote get-url origin) == "$CANONICAL_REMOTE" ]] || fail 'release checkout identity mismatch' 65
  [[ -z $(git_at "$checkout" status --porcelain) ]] || fail 'release checkout dirty' 65
}
validate_existing_root(){
  local checkout=$target/release-source receipt_file=$target/state/build-receipts/sha256-${candidate_image#sha256:}.json p
  [[ -d $target && ! -L $target && $(realpath -e -- "$target") == "$target" && $(stat -c '%u:%g:%a' "$target") == 0:0:700 ]] || fail 'existing root custody invalid' 65
  for p in bin state release-source state/build-receipts; do [[ -d $target/$p && ! -L $target/$p && $(stat -c '%u:%g:%a' "$target/$p") == 0:0:700 ]] || fail 'existing root incomplete' 65; done
  for p in hddt-moss.sh hddt-moss-launcher.sh hddt-moss-status.sh; do [[ -f $target/bin/$p && ! -L $target/bin/$p && $(stat -c '%u:%g:%a' "$target/bin/$p") == 0:0:700 ]] || fail "installed script custody invalid: $p" 65; done
  validate_release_checkout "$checkout"
  [[ $(sha "$target/bin/hddt-moss-status.sh") == $(sha "$checkout/ops/scripts/hddt-moss-status.sh") ]] || fail 'installed status script hash mismatch' 65
  validate_receipt "$receipt_file" "$target/bin/hddt-moss.sh" "$target/bin/hddt-moss-launcher.sh" "$checkout/ops/scripts/build-moss-all-in-one-candidate.sh"
}
test_mode=0; source=; revision=; tree=; candidate_image=; target=$PROD_ROOT; receipt=; receipt_hash=; git_bin=git; cron_target=/boot/config/plugins/dynamix/the-ai-crowd-hddt-retention.cron; update_cron=/usr/local/sbin/update_cron; scheduler_sync=/usr/bin/sync
while (($#)); do case $1 in
 --source-worktree) source=$2; shift 2;; --source-revision) revision=$2; shift 2;;
 --source-tree) tree=$2; shift 2;; --candidate-image-id) candidate_image=$2; shift 2;;
 --receipt) receipt=$2; shift 2;; --receipt-sha256) receipt_hash=$2; shift 2;;
 --test-target) [[ ${HDDT_BOOTSTRAP_TEST:-0} == 1 ]] || fail 'test override rejected'; test_mode=1; target=$2; shift 2;;
 --test-git-bin) [[ ${HDDT_BOOTSTRAP_TEST:-0} == 1 ]] || fail 'test override rejected'; git_bin=$2; shift 2;;
 --test-cron-target) [[ ${HDDT_BOOTSTRAP_TEST:-0} == 1 ]] || fail 'test override rejected'; cron_target=$2; shift 2;;
 --test-update-cron) [[ ${HDDT_BOOTSTRAP_TEST:-0} == 1 ]] || fail 'test override rejected'; update_cron=$2; shift 2;;
 --test-scheduler-sync) [[ ${HDDT_BOOTSTRAP_TEST:-0} == 1 ]] || fail 'test override rejected'; scheduler_sync=$2; shift 2;;
 *) fail 'usage: bootstrap-hddt-moss-root.sh --source-worktree PATH --source-revision SHA --source-tree SHA --candidate-image-id sha256:SHA --receipt PATH --receipt-sha256 SHA' 64;; esac; done
[[ -n $source && $revision =~ ^[a-f0-9]{40}$ && $tree =~ ^[a-f0-9]{40}$ && $candidate_image =~ ^sha256:[a-f0-9]{64}$ && $receipt == /* && $receipt_hash =~ ^[a-f0-9]{64}$ ]] || fail 'invalid bootstrap inputs' 64
parent=$(dirname -- "$target")
if ((test_mode)); then
 [[ $target == /tmp/hddt-bootstrap-*/* && $cron_target == /tmp/hddt-bootstrap-*/* && -x $update_cron && -x $scheduler_sync ]] || fail 'test target boundary rejected'
else
 [[ $target == "$PROD_ROOT" && $parent == "$PROD_PARENT" && $cron_target == /boot/config/plugins/dynamix/the-ai-crowd-hddt-retention.cron && $update_cron == /usr/local/sbin/update_cron && $scheduler_sync == /usr/bin/sync ]] || fail 'production target rejected'
fi
[[ -d $parent && ! -L $parent && $(realpath -e -- "$parent") == "$parent" ]] || fail 'target parent non-canonical' 65
[[ ! -L $target ]] || fail 'target symlink rejected' 65
if [[ ! -e $target && ( -e $cron_target || -L $cron_target ) ]]; then fail 'orphan retention schedule rejected' 65; fi
install_retention_schedule(){
  local source_root=${1:-$target} schedule cron_parent tmp previous= previous_present=0
  schedule=$source_root/release-source/ops/cron/the-ai-crowd-hddt-retention.cron
  cron_parent=$(dirname -- "$cron_target")
  [[ ! -L $cron_target && -f $schedule && ! -L $schedule && -d $cron_parent && ! -L $cron_parent && $(realpath -e -- "$cron_parent") == "$cron_parent" ]] || fail 'retention schedule custody invalid' 65
  if [[ -e $cron_target ]]; then
    [[ -f $cron_target && ! -L $cron_target && $(stat -c '%u:%g:%a' "$cron_target") == 0:0:600 ]] || fail 'existing retention schedule custody invalid' 65
    previous=$(mktemp "$cron_parent/.hddt-retention.previous.XXXXXX")
    if ! install -o 0 -g 0 -m 600 "$cron_target" "$previous"; then rm -f -- "$previous" || true; fail 'retention schedule snapshot failed' 65; fi
    previous_present=1
  fi
  grep -Fxq '17 * * * * /usr/bin/flock -n /mnt/ssd/appdata/the-ai-crowd-hddt/state/retention-scheduler.lock /mnt/ssd/appdata/the-ai-crowd-hddt/bin/hddt-moss.sh prune >/dev/null 2>&1' "$schedule" || { rm -f -- "$previous"; fail 'retention schedule command invalid' 65; }
  tmp=$(mktemp "$cron_parent/.hddt-retention.XXXXXX")
  if ! install -o 0 -g 0 -m 600 "$schedule" "$tmp"; then rm -f -- "$tmp" "$previous"; fail 'retention schedule copy failed' 65; fi
  if ! cmp -s "$schedule" "$tmp"; then rm -f -- "$tmp" "$previous"; fail 'retention schedule copy drift' 65; fi
  restore_retention_schedule(){
    if ((previous_present)); then
      mv -fT -- "$previous" "$cron_target" || return 1
      previous=
    else
      rm -f -- "$cron_target" || return 1
    fi
    "$scheduler_sync" "$cron_parent" || return 1
    "$update_cron" || return 1
  }
  if ! mv -T -- "$tmp" "$cron_target"; then rm -f -- "$tmp" "$previous" || fail 'retention scheduler pre-replacement cleanup failed' 74; fail 'retention schedule replacement failed' 65; fi
  if ! "$scheduler_sync" "$cron_parent"; then
    restore_retention_schedule || { rm -f -- "$previous" || true; fail 'retention scheduler rollback after sync failure failed' 74; }
    rm -f -- "$previous" || fail 'retention scheduler rollback cleanup failed' 74
    fail 'retention scheduler sync failed and was rolled back' 65
  fi
  if ! "$update_cron"; then
    restore_retention_schedule || { rm -f -- "$previous" || true; fail 'retention scheduler rollback activation failed' 74; }
    rm -f -- "$previous" || fail 'retention scheduler rollback cleanup failed' 74
    fail 'retention scheduler activation failed and was rolled back' 65
  fi
  if [[ ! -f $cron_target || -L $cron_target || $(stat -c '%u:%g:%a' "$cron_target") != 0:0:600 || $(sha "$cron_target") != $(sha "$schedule") ]]; then
    restore_retention_schedule || { rm -f -- "$previous" || true; fail 'retention scheduler rollback after readback failure failed' 74; }
    rm -f -- "$previous" || fail 'retention scheduler rollback cleanup failed' 74
    fail 'retention schedule activation readback failed and was rolled back' 65
  fi
  rm -f -- "$previous" || fail 'retention scheduler snapshot cleanup failed' 74
}
if [[ -e $target ]]; then
  validate_existing_root
  install_retention_schedule
  printf 'HDDT_BOOTSTRAP=PASS existing=yes target=%s revision=%s\n' "$target" "$revision"
  exit 0
fi
head=$(git_at "$source" rev-parse HEAD); source_tree=$(git_at "$source" rev-parse 'HEAD^{tree}'); remote=$(git_at "$source" remote get-url origin)
[[ $head == "$revision" && $source_tree == "$tree" && $remote == "$CANONICAL_REMOTE" ]] || fail 'source identity mismatch' 65
[[ -z $(git_at "$source" status --porcelain) ]] || fail 'source worktree dirty' 65
for p in hddt-moss.sh hddt-moss-launcher.sh hddt-moss-status.sh build-moss-all-in-one-candidate.sh; do [[ -f $source/ops/scripts/$p && ! -L $source/ops/scripts/$p ]] || fail "unsafe source script: $p"; done
[[ -f $receipt && ! -L $receipt ]] || fail 'receipt path unsafe' 65
stage=$(mktemp -d "$parent/.hddt-bootstrap.XXXXXX")
cleanup(){ [[ -z ${stage:-} || ! -d ${stage:-} ]] && return 0; rm -rf -- "$stage"; }
trap cleanup EXIT INT TERM ERR
chmod 700 "$stage"; mkdir -m 700 "$stage/bin" "$stage/state" "$stage/state/build-receipts"
for p in hddt-moss.sh hddt-moss-launcher.sh hddt-moss-status.sh; do install -o 0 -g 0 -m 700 "$source/ops/scripts/$p" "$stage/bin/$p"; done
"$git_bin" clone --no-local --no-hardlinks --quiet "$source" "$stage/release-source" || fail 'staged release checkout failed' 65
"$git_bin" -c safe.directory="$stage/release-source" -C "$stage/release-source" checkout --detach --quiet "$revision"
"$git_bin" -c safe.directory="$stage/release-source" -C "$stage/release-source" remote set-url origin "$CANONICAL_REMOTE"
"$git_bin" -c safe.directory="$stage/release-source" -C "$stage/release-source" config core.fileMode false
chown -R 0:0 "$stage/release-source"; find "$stage/release-source" -type d -exec chmod 700 {} +; find "$stage/release-source" -type f -exec chmod 600 {} +
install -o 0 -g 0 -m 600 "$receipt" "$stage/state/build-receipts/sha256-${candidate_image#sha256:}.json"
validate_existing_root_stage(){
  local saved_target=$target
  target=$stage
  validate_existing_root
  target=$saved_target
}
validate_existing_root_stage
install_retention_schedule "$stage"
if ! mv -T -- "$stage" "$target"; then
  rm -f -- "$cron_target" || fail 'scheduler removal after root promotion failure failed' 74
  "$scheduler_sync" "$(dirname -- "$cron_target")" || fail 'scheduler rollback sync after root promotion failure failed' 74
  "$update_cron" || fail 'scheduler rollback after root promotion failure failed' 74
  fail 'root promotion failed after scheduler activation' 65
fi
stage=; sync "$parent"
printf 'HDDT_BOOTSTRAP=PASS target=%s revision=%s\n' "$target" "$revision"
