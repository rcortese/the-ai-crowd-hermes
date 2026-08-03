#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly MOSS_PIN=321f1158b2c360a895c4a1679c000aa4ff3b7a9d
readonly MOSS_TREE_PIN=b2fa360209db0da9fe2e69a916a81ab7d00d98cf

usage() {
  cat >&2 <<'USAGE'
usage: build-moss-source-bound-base.sh \
  --tag TAG --runtime-base-image sha256:... \
  --moss-repo GIT_DIR --moss-rev COMMIT \
  --builder-repo GIT_DIR --builder-rev COMMIT --receipt FILE
USAGE
  exit 64
}

TAG= RUNTIME_BASE_IMAGE= MOSS_REPO= MOSS_REV= BUILDER_REPO= BUILDER_REV= RECEIPT=
while (($#)); do
  case "$1" in
    --tag) TAG=${2:-}; shift 2 ;;
    --runtime-base-image) RUNTIME_BASE_IMAGE=${2:-}; shift 2 ;;
    --moss-repo) MOSS_REPO=${2:-}; shift 2 ;;
    --moss-rev) MOSS_REV=${2:-}; shift 2 ;;
    --builder-repo) BUILDER_REPO=${2:-}; shift 2 ;;
    --builder-rev) BUILDER_REV=${2:-}; shift 2 ;;
    --receipt) RECEIPT=${2:-}; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n $TAG && -n $RUNTIME_BASE_IMAGE && -n $MOSS_REPO && -n $MOSS_REV && \
   -n $BUILDER_REPO && -n $BUILDER_REV && -n $RECEIPT ]] || usage
[[ $RUNTIME_BASE_IMAGE =~ ^sha256:[0-9a-f]{64}$ ]] || { echo 'runtime base image must be an immutable local image ID' >&2; exit 65; }
for rev in "$MOSS_REV" "$BUILDER_REV"; do
  [[ $rev =~ ^[0-9a-f]{40}$ ]] || { echo 'source revisions must be full Git commit IDs' >&2; exit 65; }
done
[[ $MOSS_REV == "$MOSS_PIN" ]] || { echo 'Moss revision differs from the approved pin' >&2; exit 65; }
[[ ! -e $RECEIPT ]] || { echo 'receipt already exists (write-once)' >&2; exit 65; }

GIT_BIN=${GIT_BIN:-git}
DOCKER_BIN=${DOCKER_BIN:-docker}
JQ_BIN=${JQ_BIN:-jq}
for bin in "$GIT_BIN" "$DOCKER_BIN" "$JQ_BIN"; do command -v "$bin" >/dev/null || { echo "$bin unavailable" >&2; exit 66; }; done
verify_commit() {
  local repo=$1 rev=$2 name=$3 resolved
  "$GIT_BIN" -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || { echo "$name repository unavailable" >&2; exit 66; }
  resolved=$("$GIT_BIN" -C "$repo" rev-parse --verify "$rev^{commit}") || { echo "$name commit unavailable" >&2; exit 66; }
  [[ $resolved == "$rev" ]] || { echo "$name commit identity mismatch" >&2; exit 65; }
}
verify_commit "$MOSS_REPO" "$MOSS_REV" Moss
verify_commit "$BUILDER_REPO" "$BUILDER_REV" builder
MOSS_TREE=$("$GIT_BIN" -C "$MOSS_REPO" rev-parse "$MOSS_REV^{tree}")
[[ $MOSS_TREE == "$MOSS_TREE_PIN" ]] || { echo 'Moss tree differs from the approved pin' >&2; exit 65; }

readonly BUILDER_PATH=ops/scripts/build-moss-source-bound-base.sh
readonly DOCKERFILE_PATH=ops/images/Dockerfile.moss-source-bound-base
running_builder_sha=$(sha256sum "$0" | cut -d' ' -f1)
committed_builder_sha=$("$GIT_BIN" -C "$BUILDER_REPO" show "$BUILDER_REV:$BUILDER_PATH" | sha256sum | cut -d' ' -f1)
[[ $running_builder_sha == "$committed_builder_sha" ]] || { echo 'running base builder differs from queued builder commit' >&2; exit 65; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/moss-source-bound-base.XXXXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
# Dockerfile FROM needs a local name. This content-addressed resolver alias is
# retained rather than execution-owned: concurrent executions for the same
# immutable ID may safely reuse it, and no cleanup can remove another build's alias.
BASE_ALIAS="the-ai-crowd/moss-runtime-base:${RUNTIME_BASE_IMAGE#sha256:}"

mkdir -p "$tmp/moss" "$tmp/builder"
"$GIT_BIN" -C "$MOSS_REPO" archive --format=tar "$MOSS_REV" >"$tmp/moss/source.tar"
MOSS_ARCHIVE_SHA=$(sha256sum "$tmp/moss/source.tar" | cut -d' ' -f1)
printf 'schema_version=1\ncommit=%s\ntree=%s\narchive_sha256=%s\n' \
  "$MOSS_REV" "$MOSS_TREE" "$MOSS_ARCHIVE_SHA" >"$tmp/moss/source.marker"
MOSS_MARKER_SHA=$(sha256sum "$tmp/moss/source.marker" | cut -d' ' -f1)
chmod 0444 "$tmp/moss/source.tar" "$tmp/moss/source.marker"
"$GIT_BIN" -C "$BUILDER_REPO" show "$BUILDER_REV:$DOCKERFILE_PATH" >"$tmp/builder/Dockerfile"
DOCKERFILE_SHA=$(sha256sum "$tmp/builder/Dockerfile" | cut -d' ' -f1)
chmod 0444 "$tmp/builder/Dockerfile"

[[ $("$DOCKER_BIN" image inspect "$RUNTIME_BASE_IMAGE" --format '{{.Id}}') == "$RUNTIME_BASE_IMAGE" ]] || { echo 'runtime base image unavailable or identity mismatch' >&2; exit 66; }
resolved_alias=$("$DOCKER_BIN" image inspect "$BASE_ALIAS" --format '{{.Id}}' 2>/dev/null || true)
if [[ -z $resolved_alias ]]; then
  "$DOCKER_BIN" image tag "$RUNTIME_BASE_IMAGE" "$BASE_ALIAS"
elif [[ $resolved_alias != "$RUNTIME_BASE_IMAGE" ]]; then
  echo 'content-addressed runtime-base alias resolves to another image' >&2
  exit 65
fi
[[ $("$DOCKER_BIN" image inspect "$BASE_ALIAS" --format '{{.Id}}') == "$RUNTIME_BASE_IMAGE" ]] || { echo 'runtime-base resolver alias identity mismatch' >&2; exit 65; }

"$DOCKER_BIN" build --pull=false \
  --iidfile "$tmp/image.iid" \
  --file "$tmp/builder/Dockerfile" --tag "$TAG" \
  --build-arg "MOSS_RUNTIME_BASE=$BASE_ALIAS" \
  --build-arg "MOSS_RUNTIME_BASE_ID=$RUNTIME_BASE_IMAGE" \
  --build-arg "MOSS_SOURCE_REV=$MOSS_REV" \
  --build-arg "MOSS_SOURCE_TREE=$MOSS_TREE" \
  --build-arg "MOSS_SOURCE_ARCHIVE_SHA256=$MOSS_ARCHIVE_SHA" \
  --build-arg "MOSS_SOURCE_MARKER_SHA256=$MOSS_MARKER_SHA" \
  --build-arg "BUILDER_SOURCE_REV=$BUILDER_REV" \
  --build-context "moss_source=$tmp/moss" "$tmp/builder"

[[ -f $tmp/image.iid && ! -L $tmp/image.iid ]] || { echo 'build did not produce an image ID file' >&2; exit 66; }
IMAGE_ID=$(<"$tmp/image.iid")
[[ $IMAGE_ID =~ ^sha256:[0-9a-f]{64}$ && $IMAGE_ID != "$RUNTIME_BASE_IMAGE" ]] || { echo 'invalid or unchanged source-bound base image identity' >&2; exit 66; }
[[ $("$DOCKER_BIN" image inspect "$IMAGE_ID" --format '{{.Id}}') == "$IMAGE_ID" ]] || { echo 'built source-bound base image unavailable by immutable ID' >&2; exit 66; }
# The alias is only transport for Dockerfile FROM. Close any alias race by proving
# the produced image's RootFS begins with the exact immutable runtime-base layers.
"$DOCKER_BIN" image inspect "$RUNTIME_BASE_IMAGE" >"$tmp/runtime-base.inspect.json"
"$DOCKER_BIN" image inspect "$IMAGE_ID" >"$tmp/candidate.inspect.json"
"$JQ_BIN" -e -n \
  --slurpfile base "$tmp/runtime-base.inspect.json" \
  --slurpfile candidate "$tmp/candidate.inspect.json" '
    ($base[0][0].RootFS.Layers // []) as $b
    | ($candidate[0][0].RootFS.Layers // []) as $c
    | ($b | length) > 0 and ($c[0:($b | length)] == $b)
  ' >/dev/null || { echo 'built image does not inherit the verified runtime-base layers' >&2; exit 66; }

# Publish the closed receipt without ever opening the target: mktemp uses O_EXCL,
# and hard-link publication is atomic, no-clobber, and no-follow by construction.
receipt_dir=$(dirname "$RECEIPT")
receipt_name=$(basename "$RECEIPT")
mkdir -p "$receipt_dir"
receipt_tmp=$(mktemp "$receipt_dir/.${receipt_name}.XXXXXXXX")
[[ -f $receipt_tmp && ! -L $receipt_tmp ]] || { echo 'unsafe receipt temporary file' >&2; exit 66; }
"$JQ_BIN" -cS -n \
  --arg image "$IMAGE_ID" --arg commit "$MOSS_REV" --arg tree "$MOSS_TREE" \
  '{schema:"the-ai-crowd.moss-base-provenance.v1",base_image_id:$image,moss:{commit:$commit,tree:$tree}}' \
  >"$receipt_tmp"
chmod 0600 "$receipt_tmp"
sync -f "$receipt_tmp" 2>/dev/null || sync "$receipt_tmp"
if ! ln "$receipt_tmp" "$RECEIPT" 2>/dev/null; then
  rm -f -- "$receipt_tmp"
  echo 'receipt already exists (write-once)' >&2
  exit 65
fi
rm -f -- "$receipt_tmp"
sync -f "$receipt_dir" 2>/dev/null || sync "$receipt_dir"
printf 'moss-source-bound-base-build: PASS image=%s receipt=%s archive_sha256=%s marker_sha256=%s dockerfile_sha256=%s builder_sha256=%s runtime_base=%s\n' \
  "$IMAGE_ID" "$RECEIPT" "$MOSS_ARCHIVE_SHA" "$MOSS_MARKER_SHA" "$DOCKERFILE_SHA" "$running_builder_sha" "$RUNTIME_BASE_IMAGE"
