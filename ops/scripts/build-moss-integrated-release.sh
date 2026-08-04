#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly HERMES_AGENT_PIN=8a80035101b1324d0fddb24d382d5c165868a5d0
readonly HERMES_WEBUI_PIN=400c2e3f1d779e1a9a961937c4395676088d9f4d
readonly HERMES_WEBUI_VERSION=v0.52.106-the-ai-crowd.1

usage() {
  cat >&2 <<'USAGE'
usage: build-moss-integrated-release.sh \
  --tag TAG --base-image sha256:... \
  --base-provenance-receipt FILE --base-provenance-sha256 SHA256 \
  --agent-repo GIT_DIR --agent-rev COMMIT \
  --webui-repo GIT_DIR --webui-rev COMMIT \
  --moss-repo GIT_DIR --moss-rev COMMIT \
  --builder-repo GIT_DIR --builder-rev COMMIT --receipt FILE
USAGE
  exit 64
}

TAG= BASE_IMAGE= BASE_PROVENANCE_RECEIPT= BASE_PROVENANCE_SHA256=
AGENT_REPO= AGENT_REV= WEBUI_REPO= WEBUI_REV= MOSS_REPO= MOSS_REV=
BUILDER_REPO= BUILDER_REV= RECEIPT=
while (($#)); do
  case "$1" in
    --tag) TAG=${2:-}; shift 2 ;;
    --base-image) BASE_IMAGE=${2:-}; shift 2 ;;
    --base-provenance-receipt) BASE_PROVENANCE_RECEIPT=${2:-}; shift 2 ;;
    --base-provenance-sha256) BASE_PROVENANCE_SHA256=${2:-}; shift 2 ;;
    --agent-repo) AGENT_REPO=${2:-}; shift 2 ;;
    --agent-rev) AGENT_REV=${2:-}; shift 2 ;;
    --webui-repo) WEBUI_REPO=${2:-}; shift 2 ;;
    --webui-rev) WEBUI_REV=${2:-}; shift 2 ;;
    --moss-repo) MOSS_REPO=${2:-}; shift 2 ;;
    --moss-rev) MOSS_REV=${2:-}; shift 2 ;;
    --builder-repo) BUILDER_REPO=${2:-}; shift 2 ;;
    --builder-rev) BUILDER_REV=${2:-}; shift 2 ;;
    --receipt) RECEIPT=${2:-}; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n $TAG && -n $BASE_IMAGE && -n $BASE_PROVENANCE_RECEIPT && \
   -n $BASE_PROVENANCE_SHA256 && -n $AGENT_REPO && -n $AGENT_REV && \
   -n $WEBUI_REPO && -n $WEBUI_REV && -n $MOSS_REPO && -n $MOSS_REV && \
   -n $BUILDER_REPO && -n $BUILDER_REV && -n $RECEIPT ]] || usage
[[ $BASE_IMAGE =~ ^sha256:[0-9a-f]{64}$ ]] || { echo 'base image must be an immutable local image ID' >&2; exit 65; }
[[ $BASE_PROVENANCE_SHA256 =~ ^[0-9a-f]{64}$ ]] || { echo 'base provenance checksum must be SHA-256' >&2; exit 65; }
for rev in "$AGENT_REV" "$WEBUI_REV" "$MOSS_REV" "$BUILDER_REV"; do
  [[ $rev =~ ^[0-9a-f]{40}$ ]] || { echo 'source revisions must be full Git commit IDs' >&2; exit 65; }
done
[[ $AGENT_REV == "$HERMES_AGENT_PIN" ]] || { echo 'Hermes Agent revision differs from the approved pin' >&2; exit 65; }
[[ $WEBUI_REV == "$HERMES_WEBUI_PIN" ]] || { echo 'Hermes WebUI revision differs from the approved pin' >&2; exit 65; }
[[ ! -e $RECEIPT ]] || { echo 'receipt already exists (write-once)' >&2; exit 65; }

GIT_BIN=${GIT_BIN:-git}
DOCKER_BIN=${DOCKER_BIN:-docker}
JQ_BIN=${JQ_BIN:-jq}
command -v "$GIT_BIN" >/dev/null || { echo 'git unavailable' >&2; exit 66; }
command -v "$DOCKER_BIN" >/dev/null || { echo 'docker unavailable' >&2; exit 66; }
command -v "$JQ_BIN" >/dev/null || { echo 'jq unavailable' >&2; exit 66; }

verify_commit() {
  local repo=$1 rev=$2 name=$3 resolved
  "$GIT_BIN" -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || { echo "$name repository unavailable" >&2; exit 66; }
  resolved=$("$GIT_BIN" -C "$repo" rev-parse --verify "$rev^{commit}") || { echo "$name commit unavailable" >&2; exit 66; }
  [[ $resolved == "$rev" ]] || { echo "$name commit identity mismatch" >&2; exit 65; }
}
verify_commit "$AGENT_REPO" "$AGENT_REV" 'Hermes Agent'
verify_commit "$WEBUI_REPO" "$WEBUI_REV" 'Hermes WebUI'
verify_commit "$MOSS_REPO" "$MOSS_REV" 'Moss'
verify_commit "$BUILDER_REPO" "$BUILDER_REV" 'builder'
MOSS_TREE=$("$GIT_BIN" -C "$MOSS_REPO" rev-parse "$MOSS_REV^{tree}")

readonly BUILDER_PATH=ops/scripts/build-moss-integrated-release.sh
readonly DOCKERFILE_PATH=ops/images/Dockerfile.moss-integrated-release
running_builder_sha=$(sha256sum "$0" | cut -d' ' -f1)
committed_builder_sha=$("$GIT_BIN" -C "$BUILDER_REPO" show "$BUILDER_REV:$BUILDER_PATH" | sha256sum | cut -d' ' -f1)
[[ $running_builder_sha == "$committed_builder_sha" ]] || { echo 'running builder differs from queued builder commit' >&2; exit 65; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/moss-integrated-build.XXXXXXXX")
base_alias_created=false
BASE_ALIAS="the-ai-crowd/moss-build-base:${BASE_IMAGE#sha256:}-$(basename "$tmp" | tr -cd 'A-Za-z0-9')"
cleanup() {
  local rc=$? current=
  trap - EXIT
  if [[ $base_alias_created == true ]]; then
    current=$("$DOCKER_BIN" image inspect "$BASE_ALIAS" --format '{{.Id}}' 2>/dev/null || true)
    if [[ $current == "$BASE_IMAGE" ]]; then
      if ! "$DOCKER_BIN" image rm "$BASE_ALIAS" >/dev/null; then
        echo 'failed to remove execution-owned base alias' >&2
        ((rc != 0)) || rc=70
      fi
    elif [[ -n $current ]]; then
      echo 'base alias ownership changed; refusing cleanup' >&2
      ((rc != 0)) || rc=70
    fi
  fi
  rm -rf -- "$tmp"
  exit "$rc"
}
trap cleanup EXIT

# Capture once through a bound descriptor, verify the externally pinned receipt digest,
# and require a closed binding between the immutable base image and the resolved Moss object.
[[ -f $BASE_PROVENANCE_RECEIPT && ! -L $BASE_PROVENANCE_RECEIPT ]] || { echo 'base provenance receipt must be a regular non-symlink file' >&2; exit 66; }
exec {BASE_PROVENANCE_FD}<"$BASE_PROVENANCE_RECEIPT"
[[ $(stat -Lc '%F' "/proc/$$/fd/$BASE_PROVENANCE_FD") == 'regular file' ]] || { echo 'base provenance receipt must be a regular file' >&2; exit 66; }
actual_base_provenance_sha=$(sha256sum "/proc/$$/fd/$BASE_PROVENANCE_FD" | cut -d' ' -f1)
[[ $actual_base_provenance_sha == "$BASE_PROVENANCE_SHA256" ]] || { echo 'base provenance receipt checksum mismatch' >&2; exit 65; }
cat "/proc/$$/fd/$BASE_PROVENANCE_FD" >"$tmp/base-provenance.json"
chmod 0444 "$tmp/base-provenance.json"
"$JQ_BIN" -e --arg image "$BASE_IMAGE" --arg commit "$MOSS_REV" --arg tree "$MOSS_TREE" '
  (keys | sort) == ["base_image_id","moss","schema"]
  and .schema == "the-ai-crowd.moss-base-provenance.v1"
  and .base_image_id == $image
  and .moss == {commit:$commit,tree:$tree}
' "$tmp/base-provenance.json" >/dev/null || { echo 'base provenance does not match image or resolved Moss source' >&2; exit 65; }

seal_source() {
  local name=$1 repo=$2 rev=$3
  local context="$tmp/$name" archive tree archive_sha marker_sha
  mkdir -p "$context"
  archive="$context/source.tar"
  "$GIT_BIN" -C "$repo" archive --format=tar "$rev" >"$archive"
  archive_sha=$(sha256sum "$archive" | cut -d' ' -f1)
  tree=$("$GIT_BIN" -C "$repo" rev-parse "$rev^{tree}")
  printf 'schema_version=1\ncommit=%s\ntree=%s\narchive_sha256=%s\n' \
    "$rev" "$tree" "$archive_sha" >"$context/source.marker"
  marker_sha=$(sha256sum "$context/source.marker" | cut -d' ' -f1)
  chmod 0444 "$archive" "$context/source.marker"
  printf -v "${name^^}_TREE" '%s' "$tree"
  printf -v "${name^^}_ARCHIVE_SHA" '%s' "$archive_sha"
  printf -v "${name^^}_MARKER_SHA" '%s' "$marker_sha"
}
seal_source agent "$AGENT_REPO" "$AGENT_REV"
seal_source webui "$WEBUI_REPO" "$WEBUI_REV"

mkdir -p "$tmp/builder"
"$GIT_BIN" -C "$BUILDER_REPO" show "$BUILDER_REV:$DOCKERFILE_PATH" >"$tmp/builder/Dockerfile"
DOCKERFILE_SHA=$(sha256sum "$tmp/builder/Dockerfile" | cut -d' ' -f1)
chmod 0444 "$tmp/builder/Dockerfile"

[[ $("$DOCKER_BIN" image inspect "$BASE_IMAGE" --format '{{.Id}}') == "$BASE_IMAGE" ]] || { echo 'base image unavailable or identity mismatch' >&2; exit 66; }
if "$DOCKER_BIN" image inspect "$BASE_ALIAS" --format '{{.Id}}' >/dev/null 2>&1; then
  echo 'unique base alias unexpectedly pre-exists; refusing overwrite' >&2
  exit 65
fi
"$DOCKER_BIN" image tag "$BASE_IMAGE" "$BASE_ALIAS"
base_alias_created=true
[[ $("$DOCKER_BIN" image inspect "$BASE_ALIAS" --format '{{.Id}}') == "$BASE_IMAGE" ]] || { echo 'temporary base alias identity mismatch' >&2; exit 65; }

"$DOCKER_BIN" build --pull=false \
  --file "$tmp/builder/Dockerfile" \
  --tag "$TAG" \
  --build-arg "MOSS_BASE_IMAGE=$BASE_ALIAS" \
  --build-arg "HERMES_AGENT_REV=$AGENT_REV" \
  --build-arg "HERMES_AGENT_TREE=$AGENT_TREE" \
  --build-arg "HERMES_AGENT_ARCHIVE_SHA256=$AGENT_ARCHIVE_SHA" \
  --build-arg "HERMES_AGENT_MARKER_SHA256=$AGENT_MARKER_SHA" \
  --build-arg "HERMES_WEBUI_REV=$WEBUI_REV" \
  --build-arg "HERMES_WEBUI_TREE=$WEBUI_TREE" \
  --build-arg "HERMES_WEBUI_ARCHIVE_SHA256=$WEBUI_ARCHIVE_SHA" \
  --build-arg "HERMES_WEBUI_MARKER_SHA256=$WEBUI_MARKER_SHA" \
  --build-arg "HERMES_WEBUI_VERSION=$HERMES_WEBUI_VERSION" \
  --build-arg "MOSS_SOURCE_REV=$MOSS_REV" \
  --build-arg "MOSS_SOURCE_TREE=$MOSS_TREE" \
  --build-arg "MOSS_BASE_PROVENANCE_SHA256=$BASE_PROVENANCE_SHA256" \
  --build-arg "BUILDER_SOURCE_REV=$BUILDER_REV" \
  --build-context "agent_source=$tmp/agent" \
  --build-context "webui_source=$tmp/webui" \
  "$tmp/builder"

IMAGE_ID=$("$DOCKER_BIN" image inspect "$TAG" --format '{{.Id}}')
[[ $IMAGE_ID =~ ^sha256:[0-9a-f]{64}$ ]] || { echo 'candidate image identity unavailable' >&2; exit 66; }
receipt_dir=$(dirname "$RECEIPT")
receipt_name=$(basename "$RECEIPT")
mkdir -p "$receipt_dir"
receipt_tmp=$(mktemp "$receipt_dir/.${receipt_name}.XXXXXXXX")
[[ -f $receipt_tmp && ! -L $receipt_tmp ]] || { echo 'unsafe receipt temporary file' >&2; exit 66; }
"$JQ_BIN" -cS -n \
  --arg image "$IMAGE_ID" --arg base "$BASE_IMAGE" --arg base_provenance "$BASE_PROVENANCE_SHA256" \
  --arg agent_rev "$AGENT_REV" --arg agent_tree "$AGENT_TREE" --arg agent_archive "$AGENT_ARCHIVE_SHA" --arg agent_marker "$AGENT_MARKER_SHA" \
  --arg webui_rev "$WEBUI_REV" --arg webui_tree "$WEBUI_TREE" --arg webui_archive "$WEBUI_ARCHIVE_SHA" --arg webui_marker "$WEBUI_MARKER_SHA" \
  --arg moss_rev "$MOSS_REV" --arg moss_tree "$MOSS_TREE" --arg builder_rev "$BUILDER_REV" \
  --arg dockerfile_sha "$DOCKERFILE_SHA" --arg builder_sha "$running_builder_sha" \
  '{schema_version:3,image_id:$image,base_image_id:$base,base_provenance_receipt_sha256:$base_provenance,sources:{hermes_agent:{commit:$agent_rev,tree:$agent_tree,archive_sha256:$agent_archive,marker_sha256:$agent_marker},hermes_webui:{commit:$webui_rev,tree:$webui_tree,archive_sha256:$webui_archive,marker_sha256:$webui_marker},moss:{commit:$moss_rev,tree:$moss_tree},builder:{commit:$builder_rev}},sha256:{dockerfile:$dockerfile_sha,builder:$builder_sha},production_lifecycle:false}' >"$receipt_tmp"
"$JQ_BIN" -e \
  --arg image "$IMAGE_ID" --arg base "$BASE_IMAGE" --arg base_provenance "$BASE_PROVENANCE_SHA256" \
  --arg agent_rev "$AGENT_REV" --arg agent_tree "$AGENT_TREE" --arg agent_archive "$AGENT_ARCHIVE_SHA" --arg agent_marker "$AGENT_MARKER_SHA" \
  --arg webui_rev "$WEBUI_REV" --arg webui_tree "$WEBUI_TREE" --arg webui_archive "$WEBUI_ARCHIVE_SHA" --arg webui_marker "$WEBUI_MARKER_SHA" \
  --arg moss_rev "$MOSS_REV" --arg moss_tree "$MOSS_TREE" --arg builder_rev "$BUILDER_REV" \
  --arg dockerfile_sha "$DOCKERFILE_SHA" --arg builder_sha "$running_builder_sha" '
    (keys | sort) == ["base_image_id","base_provenance_receipt_sha256","image_id","production_lifecycle","schema_version","sha256","sources"]
    and .schema_version == 3 and .image_id == $image and .base_image_id == $base and .base_provenance_receipt_sha256 == $base_provenance and .production_lifecycle == false
    and .sources.hermes_agent == {commit:$agent_rev,tree:$agent_tree,archive_sha256:$agent_archive,marker_sha256:$agent_marker}
    and .sources.hermes_webui == {commit:$webui_rev,tree:$webui_tree,archive_sha256:$webui_archive,marker_sha256:$webui_marker}
    and .sources.moss == {commit:$moss_rev,tree:$moss_tree} and .sources.builder == {commit:$builder_rev}
    and .sha256 == {dockerfile:$dockerfile_sha,builder:$builder_sha}
  ' "$receipt_tmp" >/dev/null || { rm -f -- "$receipt_tmp"; echo 'generated receipt validation failed' >&2; exit 66; }
chmod 0600 "$receipt_tmp"
sync -f "$receipt_tmp" 2>/dev/null || sync "$receipt_tmp"
if ! ln "$receipt_tmp" "$RECEIPT" 2>/dev/null; then
  rm -f -- "$receipt_tmp"
  echo 'receipt already exists (write-once)' >&2
  exit 65
fi
rm -f -- "$receipt_tmp"
sync -f "$receipt_dir" 2>/dev/null || sync "$receipt_dir"
printf 'moss-integrated-release-build: PASS image=%s receipt=%s\n' "$IMAGE_ID" "$RECEIPT"
