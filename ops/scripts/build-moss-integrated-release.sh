#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly HERMES_AGENT_PIN=d07819fd0c5acb98a745dce94d6ddce08e9b4904
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
PYTHON_BIN=${PYTHON_BIN:-python3}
command -v "$GIT_BIN" >/dev/null || { echo 'git unavailable' >&2; exit 66; }
command -v "$DOCKER_BIN" >/dev/null || { echo 'docker unavailable' >&2; exit 66; }
command -v "$PYTHON_BIN" >/dev/null || { echo 'python3 unavailable' >&2; exit 66; }

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

# Capture once through O_NOFOLLOW, verify the externally pinned receipt digest, and
# require a closed binding between the immutable base image and the resolved Moss object.
"$PYTHON_BIN" - "$BASE_PROVENANCE_RECEIPT" "$tmp/base-provenance.json" \
  "$BASE_PROVENANCE_SHA256" "$BASE_IMAGE" "$MOSS_REV" "$MOSS_TREE" <<'PY'
import hashlib, json, os, pathlib, stat, sys
src, dst, expected_sha, image, commit, tree = sys.argv[1:]
try:
    fd = os.open(src, os.O_RDONLY | os.O_NOFOLLOW)
except OSError as exc:
    raise SystemExit(f"base provenance receipt unavailable: {exc}")
try:
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        raise SystemExit("base provenance receipt must be a regular non-symlink file")
    chunks = []
    while True:
        chunk = os.read(fd, 1024 * 1024)
        if not chunk:
            break
        chunks.append(chunk)
finally:
    os.close(fd)
raw = b"".join(chunks)
actual_sha = hashlib.sha256(raw).hexdigest()
if actual_sha != expected_sha:
    raise SystemExit("base provenance receipt checksum mismatch")
try:
    data = json.loads(raw)
except (UnicodeDecodeError, json.JSONDecodeError) as exc:
    raise SystemExit(f"invalid base provenance receipt: {exc}")
if set(data) != {"schema", "base_image_id", "moss"} or data.get("schema") != "the-ai-crowd.moss-base-provenance.v1":
    raise SystemExit("base provenance receipt schema mismatch")
moss = data.get("moss")
if not isinstance(moss, dict) or set(moss) != {"commit", "tree"}:
    raise SystemExit("base provenance receipt Moss binding malformed")
if data["base_image_id"] != image or moss["commit"] != commit or moss["tree"] != tree:
    raise SystemExit("base provenance does not match image or resolved Moss source")
pathlib.Path(dst).write_bytes(raw)
PY
chmod 0444 "$tmp/base-provenance.json"

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
mkdir -p "$(dirname "$RECEIPT")"
"$PYTHON_BIN" - "$RECEIPT" "$IMAGE_ID" "$BASE_IMAGE" "$BASE_PROVENANCE_SHA256" \
  "$AGENT_REV" "$AGENT_TREE" "$AGENT_ARCHIVE_SHA" "$AGENT_MARKER_SHA" \
  "$WEBUI_REV" "$WEBUI_TREE" "$WEBUI_ARCHIVE_SHA" "$WEBUI_MARKER_SHA" \
  "$MOSS_REV" "$MOSS_TREE" "$BUILDER_REV" "$DOCKERFILE_SHA" "$running_builder_sha" <<'PY'
import json, os, pathlib, sys, tempfile
(p,image,base,base_provenance,agent_rev,agent_tree,agent_archive,agent_marker,
 webui_rev,webui_tree,webui_archive,webui_marker,moss_rev,moss_tree,builder_rev,
 dockerfile_sha,builder_sha)=sys.argv[1:]
data={
  "schema_version":3,
  "image_id":image,
  "base_image_id":base,
  "base_provenance_receipt_sha256":base_provenance,
  "sources":{
    "hermes_agent":{"commit":agent_rev,"tree":agent_tree,"archive_sha256":agent_archive,"marker_sha256":agent_marker},
    "hermes_webui":{"commit":webui_rev,"tree":webui_tree,"archive_sha256":webui_archive,"marker_sha256":webui_marker},
    "moss":{"commit":moss_rev,"tree":moss_tree},
    "builder":{"commit":builder_rev},
  },
  "sha256":{"dockerfile":dockerfile_sha,"builder":builder_sha},
  "production_lifecycle":False,
}
target=pathlib.Path(p)
payload=(json.dumps(data,indent=2,sort_keys=True)+"\n").encode()
fd,tmp=tempfile.mkstemp(prefix=f".{target.name}.",dir=target.parent)
try:
  with os.fdopen(fd,"wb") as f:
    f.write(payload); f.flush(); os.fsync(f.fileno())
  try:
    os.link(tmp,target)
  except FileExistsError:
    raise SystemExit("receipt already exists (write-once)")
  dfd=os.open(target.parent,os.O_RDONLY|os.O_DIRECTORY)
  try: os.fsync(dfd)
  finally: os.close(dfd)
finally:
  try: os.unlink(tmp)
  except FileNotFoundError: pass
PY
printf 'moss-integrated-release-build: PASS image=%s receipt=%s\n' "$IMAGE_ID" "$RECEIPT"
