#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/ops/scripts/build-moss-integrated-release.sh"
DOCKERFILE="$ROOT/ops/images/Dockerfile.moss-integrated-release"
AGENT_REPO=${1:?usage: $0 AGENT_REPO WEBUI_REPO [BUILDER_REV [BUILDER_REPO]]}
WEBUI_REPO=${2:?usage: $0 AGENT_REPO WEBUI_REPO [BUILDER_REV [BUILDER_REPO]]}
BUILDER_REV=${3:-$(git -C "$ROOT" rev-parse HEAD)}
BUILDER_REPO=${4:-$ROOT}
readonly AGENT_REV=d07819fd0c5acb98a745dce94d6ddce08e9b4904
readonly WEBUI_REV=400c2e3f1d779e1a9a961937c4395676088d9f4d
readonly MOSS_REV=321f1158b2c360a895c4a1679c000aa4ff3b7a9d
readonly BASE=sha256:f7db73a38d6c82f0534fe9b638f4891972a7714cd2eea0497ab84d5c2c53cc3a
readonly IMAGE=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

test "$(git -C "$AGENT_REPO" rev-parse "$AGENT_REV^{commit}")" = "$AGENT_REV"
test "$(git -C "$WEBUI_REPO" rev-parse "$WEBUI_REV^{commit}")" = "$WEBUI_REV"
test "$(git -C "$BUILDER_REPO" rev-parse "$BUILDER_REV^{commit}")" = "$BUILDER_REV"
bash -n "$SCRIPT"
grep -Fq "readonly HERMES_AGENT_PIN=$AGENT_REV" "$SCRIPT"
grep -Fq "readonly HERMES_WEBUI_PIN=$WEBUI_REV" "$SCRIPT"
grep -Fq '"$GIT_BIN" -C "$repo" archive --format=tar "$rev"' "$SCRIPT"
grep -Fq 'running builder differs from queued builder commit' "$SCRIPT"
grep -Fq 'receipt already exists (write-once)' "$SCRIPT"
grep -Fq 'sealed agent archive checksum mismatch' "$DOCKERFILE"
grep -Fq 'sealed agent marker checksum mismatch' "$DOCKERFILE"
grep -Fq 'sealed agent marker identity mismatch' "$DOCKERFILE"
grep -Fq 'tar -xf /tmp/sealed-agent/source.tar -C /tmp/hermes-agent-source' "$DOCKERFILE"
grep -Fq 'tar -xf /tmp/sealed-webui/source.tar -C /tmp/hermes-webui-source' "$DOCKERFILE"
grep -Fq 'test ! -e /opt/hermes/.git' "$DOCKERFILE"
grep -Fq 'org.the-ai-crowd.builder-source-revision' "$DOCKERFILE"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/docker" <<'FAKE'
#!/usr/bin/env bash
set -Eeuo pipefail
BASE=${FAKE_BASE_IMAGE:?}
IMAGE=${FAKE_IMAGE_ID:?}
if [[ ${1:-} == image && ${2:-} == inspect ]]; then
  if [[ ${3:-} == candidate:test ]]; then printf '%s\n' "$IMAGE"; else printf '%s\n' "$BASE"; fi
  exit 0
fi
if [[ ${1:-} == image && ${2:-} == tag ]]; then exit 0; fi
if [[ ${1:-} == image && ${2:-} == rm ]]; then exit 0; fi
[[ ${1:-} == build ]] || { echo "unexpected fake docker command: $*" >&2; exit 90; }
shift
declare -A arg ctx
main=
while (($#)); do
  case "$1" in
    --build-arg) key=${2%%=*}; arg[$key]=${2#*=}; shift 2 ;;
    --build-context) key=${2%%=*}; ctx[$key]=${2#*=}; shift 2 ;;
    --file|--tag) shift 2 ;;
    --pull=false) shift ;;
    *) main=$1; shift ;;
  esac
done
[[ -d $main && ! -e $main/.git ]]
for name in agent webui; do
  c=${ctx[${name}_source]:?}
  [[ -f $c/source.tar && -f $c/source.marker && ! -e $c/.git ]]
  [[ $(find "$c" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | tr '\n' ' ') == 'source.marker source.tar ' ]]
done
if [[ ${FAKE_TAMPER:-} == archive ]]; then chmod u+w "${ctx[agent_source]}/source.tar"; printf x >>"${ctx[agent_source]}/source.tar"; fi
if [[ ${FAKE_TAMPER:-} == marker || ${FAKE_TAMPER:-} == marker-reseal ]]; then
  chmod u+w "${ctx[agent_source]}/source.marker"
  printf 'tampered=true\n' >>"${ctx[agent_source]}/source.marker"
fi
if [[ ${FAKE_TAMPER:-} == marker-reseal ]]; then arg[HERMES_AGENT_MARKER_SHA256]=$(sha256sum "${ctx[agent_source]}/source.marker" | cut -d' ' -f1); fi
check() {
  local name=$1 upper=$2
  local c=${ctx[${name}_source]} marker_sha archive_sha expected
  marker_sha=$(sha256sum "$c/source.marker" | cut -d' ' -f1)
  [[ $marker_sha == "${arg[${upper}_MARKER_SHA256]}" ]] || { echo "sealed $name marker checksum mismatch actual=$marker_sha expected=${arg[${upper}_MARKER_SHA256]}" >&2; return 71; }
  expected=$(printf 'schema_version=1\ncommit=%s\ntree=%s\narchive_sha256=%s\n' \
    "${arg[${upper}_REV]}" "${arg[${upper}_TREE]}" "${arg[${upper}_ARCHIVE_SHA256]}")
  [[ $(<"$c/source.marker") == "$expected" ]] || { echo "sealed $name marker identity mismatch" >&2; return 71; }
  archive_sha=$(sha256sum "$c/source.tar" | cut -d' ' -f1)
  [[ $archive_sha == "${arg[${upper}_ARCHIVE_SHA256]}" ]] || { echo "sealed $name archive checksum mismatch" >&2; return 71; }
}
check agent HERMES_AGENT
check webui HERMES_WEBUI
for name in agent webui; do
  c=${ctx[${name}_source]}
  mkdir -p "$c/reconstructed"
  tar -xf "$c/source.tar" -C "$c/reconstructed"
  [[ ! -e $c/reconstructed/.git ]]
  [[ $(find "$c/reconstructed" -type f -print -quit) ]]
done
[[ ${arg[HERMES_AGENT_REV]} == d07819fd0c5acb98a745dce94d6ddce08e9b4904 ]]
[[ ${arg[HERMES_WEBUI_REV]} == 400c2e3f1d779e1a9a961937c4395676088d9f4d ]]
exit 0
FAKE
chmod 0755 "$tmp/bin/docker"

run_builder() {
  local receipt=$1
  PATH="$tmp/bin:$PATH" FAKE_BASE_IMAGE="$BASE" FAKE_IMAGE_ID="$IMAGE" \
    "$SCRIPT" --tag candidate:test --base-image "$BASE" \
    --agent-repo "$AGENT_REPO" --agent-rev "$AGENT_REV" \
    --webui-repo "$WEBUI_REPO" --webui-rev "$WEBUI_REV" \
    --builder-repo "$BUILDER_REPO" --builder-rev "$BUILDER_REV" \
    --moss-rev "$MOSS_REV" --receipt "$receipt"
}

(
  cd "$tmp"
  run_builder "$tmp/receipt.json"
)
python3 - "$tmp/receipt.json" "$IMAGE" "$AGENT_REV" "$WEBUI_REV" "$BUILDER_REV" <<'PY'
import json,sys
p,image,agent,webui,builder=sys.argv[1:]
d=json.load(open(p))
assert d["schema_version"] == 2
assert d["image_id"] == image
assert d["sources"]["hermes_agent"]["commit"] == agent
assert d["sources"]["hermes_webui"]["commit"] == webui
assert d["sources"]["builder"]["commit"] == builder
for name in ("hermes_agent","hermes_webui"):
    assert len(d["sources"][name]["archive_sha256"]) == 64
    assert len(d["sources"][name]["marker_sha256"]) == 64
assert d["production_lifecycle"] is False
PY
set +e
out=$(run_builder "$tmp/receipt.json" 2>&1); rc=$?
set -e
[[ $rc -eq 65 && $out == *'receipt already exists (write-once)'* ]]

for scenario in archive marker marker-reseal; do
  set +e
  out=$(FAKE_TAMPER=$scenario run_builder "$tmp/$scenario.json" 2>&1); rc=$?
  set -e
  [[ $rc -ne 0 ]]
  case $scenario in
    archive) [[ $out == *'sealed agent archive checksum mismatch'* ]] ;;
    marker) [[ $out == *'sealed agent marker checksum mismatch'* ]] ;;
    marker-reseal) [[ $out == *'sealed agent marker identity mismatch'* ]] ;;
  esac
  [[ ! -e $tmp/$scenario.json ]]
done

set +e
out=$(PATH="$tmp/bin:$PATH" FAKE_BASE_IMAGE="$BASE" FAKE_IMAGE_ID="$IMAGE" \
  "$SCRIPT" --tag candidate:test --base-image "$BASE" \
  --agent-repo "$AGENT_REPO" --agent-rev 0000000000000000000000000000000000000000 \
  --webui-repo "$WEBUI_REPO" --webui-rev "$WEBUI_REV" \
  --builder-repo "$BUILDER_REPO" --builder-rev "$BUILDER_REV" \
  --moss-rev "$MOSS_REV" --receipt "$tmp/wrong-pin.json" 2>&1); rc=$?
set -e
[[ $rc -eq 65 && $out == *'Hermes Agent revision differs from the approved pin'* ]]
[[ ! -e $tmp/wrong-pin.json ]]
printf '%s\n' 'test-build-moss-integrated-release: PASS sealed-archives=2 causal-tamper=3 write-once=PASS cwd-independent=PASS'
