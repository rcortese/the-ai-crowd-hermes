#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
readonly PROD_ROOT=/mnt/ssd/appdata/the-ai-crowd-hddt
readonly PROD_PARENT=/mnt/ssd/appdata
readonly CANONICAL_REMOTE=git@github.com:rcortese/the-ai-crowd-hermes.git
readonly PROD_REVISION=e559b9ac2516920b75fe56a12a7d7a358a89c118
readonly PROD_TREE=6c471d1c2a78b4d24b633a916c75684f9254ed56
readonly CANDIDATE_IMAGE=sha256:b80f5a9a93faa6dea369b2c37648753110a3126eae24ff821065fe89e65628fb
readonly RECEIPT_PATH=/mnt/ssd/appdata/the-ai-crowd-hddt-preprod/build-receipts/sha256-b80f5a9a93faa6dea369b2c37648753110a3126eae24ff821065fe89e65628fb.json
readonly RECEIPT_HASH=2f27b60d1ef30f9c388d44265153a3d3e76358fad9615a3ab09ae28e07c94ca3
fail(){ printf 'HDDT bootstrap: %s\n' "$1" >&2; exit "${2:-65}"; }
sha(){ sha256sum -- "$1" | cut -d' ' -f1; }
git_at(){ GIT_OPTIONAL_LOCKS=0 "$git_bin" -c safe.directory="$1" -C "$1" "${@:2}"; }
validate_receipt(){
  local receipt_file=$1 executor=$2 launcher=$3 builder=$4
  [[ -f $receipt_file && ! -L $receipt_file && $(stat -c '%u:%g:%a' "$receipt_file") == 0:0:600 && $(sha "$receipt_file") == "$receipt_hash" ]] || fail 'receipt custody or bytes mismatch' 65
  jq -e --arg rev "$revision" --arg tree "$tree" --arg remote "$CANONICAL_REMOTE" --arg image "$CANDIDATE_IMAGE" --arg exec "$(sha "$executor")" --arg launcher "$(sha "$launcher")" --arg builder "$(sha "$builder")" '.source_revision==$rev and .source_tree==$tree and .source_remote==$remote and .candidate_image_id==$image and .executor_sha256==$exec and .launcher_sha256==$launcher and .builder_sha256==$builder' "$receipt_file" >/dev/null || fail 'receipt component binding mismatch' 65
}
validate_release_checkout(){
  local checkout=$1
  [[ -d $checkout && ! -L $checkout && $(stat -c '%u:%g:%a' "$checkout") == 0:0:700 ]] || fail 'release checkout custody invalid' 65
  [[ $(git_at "$checkout" rev-parse HEAD) == "$revision" && $(git_at "$checkout" rev-parse 'HEAD^{tree}') == "$tree" && $(git_at "$checkout" remote get-url origin) == "$CANONICAL_REMOTE" ]] || fail 'release checkout identity mismatch' 65
  [[ -z $(git_at "$checkout" status --porcelain) ]] || fail 'release checkout dirty' 65
}
validate_existing_root(){
  local checkout=$target/release-source receipt_file=$target/state/build-receipts/sha256-${CANDIDATE_IMAGE#sha256:}.json p
  [[ -d $target && ! -L $target && $(realpath -e -- "$target") == "$target" && $(stat -c '%u:%g:%a' "$target") == 0:0:700 ]] || fail 'existing root custody invalid' 65
  for p in bin state release-source state/build-receipts; do [[ -d $target/$p && ! -L $target/$p && $(stat -c '%u:%g:%a' "$target/$p") == 0:0:700 ]] || fail 'existing root incomplete' 65; done
  for p in hddt-moss.sh hddt-moss-launcher.sh hddt-moss-status.sh; do [[ -f $target/bin/$p && ! -L $target/bin/$p && $(stat -c '%u:%g:%a' "$target/bin/$p") == 0:0:700 ]] || fail "installed script custody invalid: $p" 65; done
  validate_release_checkout "$checkout"
  [[ $(sha "$target/bin/hddt-moss-status.sh") == $(sha "$checkout/ops/scripts/hddt-moss-status.sh") ]] || fail 'installed status script hash mismatch' 65
  validate_receipt "$receipt_file" "$target/bin/hddt-moss.sh" "$target/bin/hddt-moss-launcher.sh" "$checkout/ops/scripts/build-moss-all-in-one-candidate.sh"
}
test_mode=0; source=; revision=$PROD_REVISION; tree=$PROD_TREE; target=$PROD_ROOT; receipt=$RECEIPT_PATH; receipt_hash=$RECEIPT_HASH; git_bin=git
while (($#)); do case $1 in
 --source-worktree) source=$2; shift 2;; --source-revision) revision=$2; shift 2;;
 --test-target) [[ ${HDDT_BOOTSTRAP_TEST:-0} == 1 ]] || fail 'test override rejected'; test_mode=1; target=$2; shift 2;;
 --test-source-tree) [[ ${HDDT_BOOTSTRAP_TEST:-0} == 1 ]] || fail 'test override rejected'; tree=$2; shift 2;;
 --test-receipt) [[ ${HDDT_BOOTSTRAP_TEST:-0} == 1 ]] || fail 'test override rejected'; receipt=$2; shift 2;;
 --test-receipt-sha256) [[ ${HDDT_BOOTSTRAP_TEST:-0} == 1 ]] || fail 'test override rejected'; receipt_hash=$2; shift 2;;
 --test-git-bin) [[ ${HDDT_BOOTSTRAP_TEST:-0} == 1 ]] || fail 'test override rejected'; git_bin=$2; shift 2;;
 *) fail 'usage: bootstrap-hddt-moss-root.sh --source-worktree PATH [--source-revision SHA]' 64;; esac; done
[[ -n $source && $revision =~ ^[a-f0-9]{40}$ && $tree =~ ^[a-f0-9]{40}$ && $receipt_hash =~ ^[a-f0-9]{64}$ ]] || fail 'invalid bootstrap inputs' 64
parent=$(dirname -- "$target")
if ((test_mode)); then [[ $target == /tmp/hddt-bootstrap-*/* ]] || fail 'test target boundary rejected'; else [[ $target == "$PROD_ROOT" && $parent == "$PROD_PARENT" ]] || fail 'production target rejected'; fi
[[ -d $parent && ! -L $parent && $(realpath -e -- "$parent") == "$parent" ]] || fail 'target parent non-canonical' 65
[[ ! -L $target ]] || fail 'target symlink rejected' 65
if [[ -e $target ]]; then
  validate_existing_root
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
install -o 0 -g 0 -m 600 "$receipt" "$stage/state/build-receipts/sha256-${CANDIDATE_IMAGE#sha256:}.json"
validate_existing_root_stage(){
  local saved_target=$target
  target=$stage
  validate_existing_root
  target=$saved_target
}
validate_existing_root_stage
mv -T -- "$stage" "$target"; stage=; sync "$parent"
printf 'HDDT_BOOTSTRAP=PASS target=%s revision=%s\n' "$target" "$revision"
