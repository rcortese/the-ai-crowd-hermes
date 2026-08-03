#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf '%s\n' "usage: $0 --tag TAG --base-image sha256:... --agent-source DIR --agent-rev COMMIT --webui-source DIR --webui-rev COMMIT --moss-rev COMMIT --receipt FILE" >&2
  exit 64
}

TAG= BASE_IMAGE= AGENT_SOURCE= AGENT_REV= WEBUI_SOURCE= WEBUI_REV= MOSS_REV= RECEIPT=
while (($#)); do
  case "$1" in
    --tag) TAG=${2:-}; shift 2 ;;
    --base-image) BASE_IMAGE=${2:-}; shift 2 ;;
    --agent-source) AGENT_SOURCE=${2:-}; shift 2 ;;
    --agent-rev) AGENT_REV=${2:-}; shift 2 ;;
    --webui-source) WEBUI_SOURCE=${2:-}; shift 2 ;;
    --webui-rev) WEBUI_REV=${2:-}; shift 2 ;;
    --moss-rev) MOSS_REV=${2:-}; shift 2 ;;
    --receipt) RECEIPT=${2:-}; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n $TAG && -n $BASE_IMAGE && -n $AGENT_SOURCE && -n $AGENT_REV && -n $WEBUI_SOURCE && -n $WEBUI_REV && -n $MOSS_REV && -n $RECEIPT ]] || usage
[[ $BASE_IMAGE =~ ^sha256:[0-9a-f]{64}$ ]] || { echo 'base image must be an immutable local image ID' >&2; exit 65; }
[[ $AGENT_REV =~ ^[0-9a-f]{40}$ && $WEBUI_REV =~ ^[0-9a-f]{40}$ && $MOSS_REV =~ ^[0-9a-f]{40}$ ]] || { echo 'source revisions must be full Git commit IDs' >&2; exit 65; }
for spec in "$AGENT_SOURCE:$AGENT_REV:agent" "$WEBUI_SOURCE:$WEBUI_REV:webui"; do
  IFS=: read -r path rev name <<<"$spec"
  [[ -d $path/.git ]] || { echo "$name source is not a Git checkout" >&2; exit 66; }
  [[ $(git -C "$path" rev-parse HEAD) == "$rev" ]] || { echo "$name source revision mismatch" >&2; exit 65; }
  [[ -z $(git -C "$path" status --porcelain) ]] || { echo "$name source is dirty" >&2; exit 65; }
done
[[ $(docker image inspect "$BASE_IMAGE" --format '{{.Id}}') == "$BASE_IMAGE" ]] || { echo 'base image unavailable or identity mismatch' >&2; exit 66; }
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
DOCKERFILE="$ROOT/ops/images/Dockerfile.moss-integrated-release"
[[ -f $DOCKERFILE ]] || { echo 'integrated release Dockerfile missing' >&2; exit 66; }
mkdir -p "$(dirname "$RECEIPT")"
BASE_ALIAS="the-ai-crowd/moss-build-base:${BASE_IMAGE#sha256:}"
cleanup() { docker image rm "$BASE_ALIAS" >/dev/null 2>&1 || true; }
trap cleanup EXIT
docker image tag "$BASE_IMAGE" "$BASE_ALIAS"
[[ $(docker image inspect "$BASE_ALIAS" --format '{{.Id}}') == "$BASE_IMAGE" ]] || { echo 'temporary base alias identity mismatch' >&2; exit 65; }

docker build --pull=false \
  --file "$DOCKERFILE" \
  --tag "$TAG" \
  --build-arg "MOSS_BASE_IMAGE=$BASE_ALIAS" \
  --build-arg "HERMES_AGENT_REV=$AGENT_REV" \
  --build-arg "HERMES_WEBUI_REV=$WEBUI_REV" \
  --build-arg "MOSS_SOURCE_REV=$MOSS_REV" \
  --build-context "agent_source=$AGENT_SOURCE" \
  --build-context "webui_source=$WEBUI_SOURCE" \
  "$ROOT"
IMAGE_ID=$(docker image inspect "$TAG" --format '{{.Id}}')
[[ $IMAGE_ID =~ ^sha256:[0-9a-f]{64}$ ]] || { echo 'candidate image identity unavailable' >&2; exit 66; }
python3 - "$RECEIPT" "$IMAGE_ID" "$BASE_IMAGE" "$AGENT_REV" "$WEBUI_REV" "$MOSS_REV" "$(sha256sum "$DOCKERFILE" | cut -d' ' -f1)" "$(sha256sum "$0" | cut -d' ' -f1)" <<'PY'
import json,sys
p,image,base,agent,webui,moss,dockerfile,builder=sys.argv[1:]
data={"schema_version":1,"image_id":image,"base_image_id":base,"sources":{"hermes_agent":agent,"hermes_webui":webui,"moss":moss},"sha256":{"dockerfile":dockerfile,"builder":builder},"production_lifecycle":False}
open(p,'w').write(json.dumps(data,indent=2,sort_keys=True)+'\n')
PY
printf 'moss-integrated-release-build: PASS image=%s receipt=%s\n' "$IMAGE_ID" "$RECEIPT"
