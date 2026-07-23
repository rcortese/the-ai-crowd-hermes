#!/usr/bin/env bash
set -euo pipefail

# Build from an exported clean commit and a hash-pinned private Node input.
# Bind the export to this script's repository, never to the caller's cwd.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
git -C "$ROOT" rev-parse --show-toplevel >/dev/null
COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
SOURCE_BASE_REVISION="${HDDT_SOURCE_BASE_REVISION:-}"
if [[ ! $SOURCE_BASE_REVISION =~ ^[0-9a-f]{40}$ ]]; then
  printf '%s\n' 'invalid explicit HDDT source base revision' >&2
  exit 65
fi
source_base_canonical=$(git -C "$ROOT" rev-parse --verify "${SOURCE_BASE_REVISION}^{commit}") || { printf '%s\n' 'explicit HDDT source base revision unavailable' >&2; exit 65; }
[[ $source_base_canonical == "$SOURCE_BASE_REVISION" && $SOURCE_BASE_REVISION != "$COMMIT" ]] || { printf '%s\n' 'explicit HDDT source base revision mismatches source revision' >&2; exit 65; }
git -C "$ROOT" merge-base --is-ancestor "$SOURCE_BASE_REVISION" "$COMMIT" || { printf '%s\n' 'explicit HDDT source base revision is not an ancestor' >&2; exit 65; }
INPUT_DIR="${CLASH_ROYALE_BUILD_INPUT_DIR:-}"
[[ -n $INPUT_DIR ]] || { printf '%s\n' 'missing controlled private Node build input directory' >&2; exit 65; }
BASE_IMAGE="${MOSS_BASE_IMAGE:-}"
[[ $BASE_IMAGE =~ ^sha256:[0-9a-f]{64}$ ]] || { printf '%s\n' 'MOSS_BASE_IMAGE must be an immutable local sha256 image ID' >&2; exit 65; }
TAG="${1:?usage: $0 IMAGE_TAG}"
MANIFEST_REL="ops/build-inputs/moss-clash-royale-war-bot.sha256"

if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
  printf '%s\n' 'refusing dirty source worktree' >&2
  exit 1
fi
for name in package.json package-lock.json; do
  test -f "$INPUT_DIR/$name" || { printf 'missing private build input: %s\n' "$name" >&2; exit 1; }
done

CTX="$(mktemp -d "${TMPDIR:-/tmp}/moss-release-context.XXXXXX")"
trap 'rm -rf "$CTX"' EXIT
git -C "$ROOT" archive --format=tar "$COMMIT" | tar -xf - -C "$CTX"
(
  cd "$INPUT_DIR"
  sha256sum -c "$CTX/$MANIFEST_REL"
) || { printf '%s\n' 'private build input checksum mismatch' >&2; exit 65; }
resolved_base=$(docker image inspect "$BASE_IMAGE" --format '{{.Id}}') || { printf '%s\n' 'immutable Moss base image is unavailable locally' >&2; exit 65; }
[[ $resolved_base == "$BASE_IMAGE" ]] || { printf '%s\n' 'Moss base image ID resolution mismatch' >&2; exit 65; }
docker build --pull=false \
  --file "$CTX/ops/images/Dockerfile.moss-all-in-one" \
  --tag "$TAG" \
  --build-arg "MOSS_BASE_IMAGE=$BASE_IMAGE" \
  --build-context "clash_royale_build_input=$INPUT_DIR" \
  "$CTX"
docker image inspect "$TAG" --format 'tag={{index .RepoTags 0}} image={{.Id}} created={{.Created}}'

# A build receipt is authority for prepare only after this source-only producer
# publishes it write-once. It contains hashes/identifiers, never rendered env.
BUILD_RECEIPT_ROOT=${BUILD_RECEIPT_ROOT:?set BUILD_RECEIPT_ROOT to the host-only receipt root}
[[ $BUILD_RECEIPT_ROOT == /* && ! -L $BUILD_RECEIPT_ROOT ]] || { printf '%s\n' 'unsafe build receipt root' >&2; exit 65; }
if [[ ! -e $BUILD_RECEIPT_ROOT ]]; then parent=$(realpath -e -- "$(dirname "$BUILD_RECEIPT_ROOT")") || exit 65; [[ ! -L $parent ]] || exit 65; mkdir -m 700 -- "$BUILD_RECEIPT_ROOT"; fi
[[ $(realpath -e -- "$BUILD_RECEIPT_ROOT") == "$BUILD_RECEIPT_ROOT" && $(stat -c %u "$BUILD_RECEIPT_ROOT") == "$(id -u)" ]] || { printf '%s\n' 'receipt root custody mismatch' >&2; exit 65; }
chmod 700 "$BUILD_RECEIPT_ROOT"
image_id=$(docker image inspect "$TAG" --format '{{.Id}}')
[[ $image_id =~ ^sha256:[0-9a-f]{64}$ ]] || { printf '%s\n' 'invalid candidate image ID' >&2; exit 65; }
tree=$(git -C "$ROOT" rev-parse "$COMMIT^{tree}")
source_remote=$(git -C "$ROOT" remote get-url origin)
context_sha=$(git -C "$ROOT" ls-tree -r "$COMMIT" | sha256sum | cut -d' ' -f1)
closure_manifest_rel=ops/manifests/moss-release-source-closure.paths
closure_manifest="$ROOT/$closure_manifest_rel"
[[ -f $closure_manifest && ! -L $closure_manifest ]] || { printf '%s\n' 'release source closure manifest missing or unsafe' >&2; exit 65; }
mapfile -t closure_paths <"$closure_manifest"
((${#closure_paths[@]} > 0)) || { printf '%s\n' 'release source closure manifest empty' >&2; exit 65; }
LC_ALL=C sort -cu "$closure_manifest" || { printf '%s\n' 'release source closure manifest must be sorted and unique' >&2; exit 65; }
for path in "${closure_paths[@]}"; do
  [[ $path != /* && $path != *'..'* && -n $path ]] || { printf '%s\n' 'invalid release source closure path' >&2; exit 65; }
  git -C "$ROOT" ls-files --error-unmatch -- "$path" >/dev/null || { printf 'untracked release source closure path: %s\n' "$path" >&2; exit 65; }
done
source_closure_sha=$(git -C "$ROOT" ls-tree -r --full-tree "$COMMIT" -- "${closure_paths[@]}" | sha256sum | cut -d' ' -f1)
[[ $source_closure_sha =~ ^[0-9a-f]{64}$ ]] || { printf '%s\n' 'release source closure hash unavailable' >&2; exit 65; }
hddt_executor_sha=$(sha256sum "$ROOT/ops/scripts/hddt-moss.sh" | cut -d' ' -f1)
[[ $hddt_executor_sha =~ ^[0-9a-f]{64}$ ]] || { printf '%s\n' 'HDDT executor hash unavailable' >&2; exit 65; }
toolchain_sha=$( { docker version --format '{{json .}}'; docker buildx version; } | sha256sum | cut -d' ' -f1)
created_epoch=$(git -C "$ROOT" show -s --format=%ct "$COMMIT")
[[ $created_epoch =~ ^[0-9]+$ ]] || { printf '%s\n' 'invalid source commit epoch' >&2; exit 65; }
receipt="$BUILD_RECEIPT_ROOT/sha256-${image_id#sha256:}.json"
tmp=$(mktemp "$BUILD_RECEIPT_ROOT/.receipt.XXXXXX")
jq -ncS --arg rev "$COMMIT" --arg source_base "$SOURCE_BASE_REVISION" --arg tree "$tree" --arg remote "$source_remote" --arg closure "$source_closure_sha" --arg image "$image_id" --arg base "$BASE_IMAGE" --arg context "$context_sha" --arg exec "$hddt_executor_sha" --arg toolchain "$toolchain_sha" --argjson created "$created_epoch" '{source_revision:$rev,source_base_revision:$source_base,source_tree:$tree,source_remote:$remote,source_closure_sha256:$closure,candidate_image_id:$image,base_image:$base,context_sha256:$context,executor_sha256:$exec,toolchain_sha256:$toolchain,created_epoch:$created}' >"$tmp"
chmod 600 "$tmp"; sync "$tmp"
if [[ -e $receipt ]]; then [[ -f $receipt && ! -L $receipt ]] && cmp -s "$tmp" "$receipt" || { rm -f "$tmp"; printf '%s\n' 'divergent or unsafe build receipt already exists' >&2; exit 65; }; rm -f "$tmp"; else ln "$tmp" "$receipt" || { rm -f "$tmp"; printf '%s\n' 'receipt publication race' >&2; exit 65; }; rm -f "$tmp"; sync "$BUILD_RECEIPT_ROOT"; fi
printf 'build-receipt=%s sha256=%s\n' "$receipt" "$(sha256sum "$receipt" | cut -d' ' -f1)"