#!/usr/bin/env bash
set -euo pipefail

# Build from an exported clean commit and a hash-pinned private Node input.
# Bind the export to this script's repository, never to the caller's cwd.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
git -C "$ROOT" rev-parse --show-toplevel >/dev/null
COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
INPUT_DIR="${CLASH_ROYALE_BUILD_INPUT_DIR:?set CLASH_ROYALE_BUILD_INPUT_DIR to the controlled private Node input directory}"
BASE_IMAGE="${MOSS_BASE_IMAGE:?set MOSS_BASE_IMAGE to the reviewed immutable Moss base image}"
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
)
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
source_closure_sha=$( { git -C "$ROOT" ls-tree -r "$COMMIT"; sha256sum "$CTX/$MANIFEST_REL"; } | sha256sum | cut -d' ' -f1)
script_sha=$(sha256sum "$0" | cut -d' ' -f1)
toolchain_sha=$( { docker version --format '{{json .}}'; docker buildx version; } | sha256sum | cut -d' ' -f1)
receipt="$BUILD_RECEIPT_ROOT/sha256-${image_id#sha256:}.json"
tmp=$(mktemp "$BUILD_RECEIPT_ROOT/.receipt.XXXXXX")
jq -ncS --arg rev "$COMMIT" --arg tree "$tree" --arg remote "$source_remote" --arg closure "$source_closure_sha" --arg image "$image_id" --arg base "$BASE_IMAGE" --arg context "$context_sha" --arg exec "$script_sha" --arg toolchain "$toolchain_sha" --argjson created "$(date -u +%s)" '{source_revision:$rev,source_tree:$tree,source_remote:$remote,source_closure_sha256:$closure,candidate_image_id:$image,base_image:$base,context_sha256:$context,executor_sha256:$exec,toolchain_sha256:$toolchain,created_epoch:$created}' >"$tmp"
chmod 600 "$tmp"; sync "$tmp"
if [[ -e $receipt ]]; then [[ -f $receipt && ! -L $receipt ]] && cmp -s "$tmp" "$receipt" || { rm -f "$tmp"; printf '%s\n' 'divergent or unsafe build receipt already exists' >&2; exit 65; }; rm -f "$tmp"; else ln "$tmp" "$receipt" || { rm -f "$tmp"; printf '%s\n' 'receipt publication race' >&2; exit 65; }; rm -f "$tmp"; sync "$BUILD_RECEIPT_ROOT"; fi
printf 'build-receipt=%s sha256=%s\n' "$receipt" "$(sha256sum "$receipt" | cut -d' ' -f1)"