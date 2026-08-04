#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/ops/scripts/build-moss-integrated-release.sh"
DOCKERFILE="$ROOT/ops/images/Dockerfile.moss-integrated-release"
AGENT_REPO=${1:?usage: $0 AGENT_REPO WEBUI_REPO MOSS_REPO [BUILDER_REV [BUILDER_REPO]]}
WEBUI_REPO=${2:?usage: $0 AGENT_REPO WEBUI_REPO MOSS_REPO [BUILDER_REV [BUILDER_REPO]]}
MOSS_REPO=${3:?usage: $0 AGENT_REPO WEBUI_REPO MOSS_REPO [BUILDER_REV [BUILDER_REPO]]}
BUILDER_REV=${4:-$(git -C "$ROOT" rev-parse HEAD)}
BUILDER_REPO=${5:-$ROOT}
readonly AGENT_REV=8a80035101b1324d0fddb24d382d5c165868a5d0
readonly WEBUI_REV=400c2e3f1d779e1a9a961937c4395676088d9f4d
readonly MOSS_REV=321f1158b2c360a895c4a1679c000aa4ff3b7a9d
readonly MOSS_TREE=b2fa360209db0da9fe2e69a916a81ab7d00d98cf
readonly BASE=sha256:f7db73a38d6c82f0534fe9b638f4891972a7714cd2eea0497ab84d5c2c53cc3a
readonly OTHER=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
readonly IMAGE=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
JQ_BIN=${JQ_BIN:-jq}
command -v "$JQ_BIN" >/dev/null

test "$(git -C "$AGENT_REPO" rev-parse "$AGENT_REV^{commit}")" = "$AGENT_REV"
test "$(git -C "$WEBUI_REPO" rev-parse "$WEBUI_REV^{commit}")" = "$WEBUI_REV"
test "$(git -C "$MOSS_REPO" rev-parse "$MOSS_REV^{commit}")" = "$MOSS_REV"
test "$(git -C "$MOSS_REPO" rev-parse "$MOSS_REV^{tree}")" = "$MOSS_TREE"
test "$(git -C "$BUILDER_REPO" rev-parse "$BUILDER_REV^{commit}")" = "$BUILDER_REV"
bash -n "$SCRIPT"
grep -Fq "readonly HERMES_AGENT_PIN=$AGENT_REV" "$SCRIPT"
grep -Fq "readonly HERMES_WEBUI_PIN=$WEBUI_REV" "$SCRIPT"
grep -Fq 'verify_commit "$MOSS_REPO" "$MOSS_REV"' "$SCRIPT"
grep -Fq 'base provenance does not match image or resolved Moss source' "$SCRIPT"
grep -Fq 'unique base alias unexpectedly pre-exists; refusing overwrite' "$SCRIPT"
grep -Fq 'base alias ownership changed; refusing cleanup' "$SCRIPT"
grep -Fq '"$GIT_BIN" -C "$repo" archive --format=tar "$rev"' "$SCRIPT"
grep -Fq 'running builder differs from queued builder commit' "$SCRIPT"
grep -Fq 'receipt already exists (write-once)' "$SCRIPT"
grep -Fq 'sealed agent archive checksum mismatch' "$DOCKERFILE"
grep -Fq 'sealed agent marker checksum mismatch' "$DOCKERFILE"
grep -Fq 'sealed agent marker identity mismatch' "$DOCKERFILE"
grep -Fq 'tar -xf /tmp/sealed-agent/source.tar -C /tmp/hermes-agent-source' "$DOCKERFILE"
grep -Fq 'tar -xf /tmp/sealed-webui/source.tar -C /tmp/hermes-webui-source' "$DOCKERFILE"
grep -Fq 'test ! -e /opt/hermes/.git' "$DOCKERFILE"
grep -Fq 'org.the-ai-crowd.moss-source-tree' "$DOCKERFILE"
grep -Fq 'org.the-ai-crowd.moss-base-provenance-sha256' "$DOCKERFILE"
grep -Fq 'org.the-ai-crowd.builder-source-revision' "$DOCKERFILE"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/fake-state/aliases"
printf '{"schema":"the-ai-crowd.moss-base-provenance.v1","base_image_id":"%s","moss":{"commit":"%s","tree":"%s"}}\n' \
  "$BASE" "$MOSS_REV" "$MOSS_TREE" >"$tmp/base-provenance.json"
BASE_PROVENANCE_SHA=$(sha256sum "$tmp/base-provenance.json" | cut -d' ' -f1)

cat >"$tmp/bin/docker" <<'FAKE'
#!/usr/bin/env bash
set -Eeuo pipefail
BASE=${FAKE_BASE_IMAGE:?}
IMAGE=${FAKE_IMAGE_ID:?}
STATE=${FAKE_STATE:?}
key() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
if [[ ${1:-} == image && ${2:-} == inspect ]]; then
  ref=${3:-}
  if [[ $ref == "$BASE" ]]; then printf '%s\n' "$BASE"; exit 0; fi
  if [[ $ref == candidate:* ]]; then printf '%s\n' "$IMAGE"; exit 0; fi
  if [[ $ref == the-ai-crowd/moss-build-base:* ]]; then
    if [[ ${FAKE_PREEXIST_ALIAS:-} == true ]]; then printf '%s\n' "${FAKE_OTHER_IMAGE:?}"; exit 0; fi
    file="$STATE/aliases/$(key "$ref")"
    [[ -f $file ]] || exit 1
    IFS= read -r value <"$file"
    printf '%s\n' "$value"
    exit 0
  fi
  exit 1
fi
if [[ ${1:-} == image && ${2:-} == tag ]]; then
  src=${3:?}; dst=${4:?}
  [[ $src == "$BASE" && $dst == the-ai-crowd/moss-build-base:* ]]
  file="$STATE/aliases/$(key "$dst")"
  printf '%s\n' "$BASE" >"$file"
  printf '%s\n' "$dst" >>"$STATE/tagged.log"
  exit 0
fi
if [[ ${1:-} == image && ${2:-} == rm ]]; then
  ref=${3:?}; file="$STATE/aliases/$(key "$ref")"
  [[ -f $file ]]
  rm -- "$file"
  printf '%s\n' "$ref" >>"$STATE/removed.log"
  exit 0
fi
[[ ${1:-} == build ]] || { echo "unexpected fake docker command: $*" >&2; exit 90; }
shift
declare -A arg ctx
main=
while (($#)); do
  case "$1" in
    --build-arg) key_name=${2%%=*}; arg[$key_name]=${2#*=}; shift 2 ;;
    --build-context) key_name=${2%%=*}; ctx[$key_name]=${2#*=}; shift 2 ;;
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
[[ ${arg[HERMES_AGENT_REV]} == 8a80035101b1324d0fddb24d382d5c165868a5d0 ]]
[[ ${arg[HERMES_WEBUI_REV]} == 400c2e3f1d779e1a9a961937c4395676088d9f4d ]]
[[ ${arg[MOSS_SOURCE_REV]} == 321f1158b2c360a895c4a1679c000aa4ff3b7a9d ]]
[[ ${arg[MOSS_SOURCE_TREE]} == b2fa360209db0da9fe2e69a916a81ab7d00d98cf ]]
[[ ${arg[MOSS_BASE_PROVENANCE_SHA256]} == "${FAKE_BASE_PROVENANCE_SHA:?}" ]]
[[ -n ${FAKE_BUILD_DELAY:-} ]] && sleep "$FAKE_BUILD_DELAY"
exit 0
FAKE
chmod 0755 "$tmp/bin/docker"
printf '%s\n' '#!/usr/bin/env bash' 'echo python3-must-not-run >&2' 'exit 99' >"$tmp/bin/python3"
chmod 0755 "$tmp/bin/python3"

run_builder() {
  local receipt=$1 provenance=${2:-$tmp/base-provenance.json} provenance_sha=${3:-$BASE_PROVENANCE_SHA} tag=${4:-candidate:test}
  PATH="$tmp/bin:$PATH" FAKE_BASE_IMAGE="$BASE" FAKE_OTHER_IMAGE="$OTHER" FAKE_IMAGE_ID="$IMAGE" \
    FAKE_STATE="$tmp/fake-state" FAKE_BASE_PROVENANCE_SHA="$BASE_PROVENANCE_SHA" \
    "$SCRIPT" --tag "$tag" --base-image "$BASE" \
    --base-provenance-receipt "$provenance" --base-provenance-sha256 "$provenance_sha" \
    --agent-repo "$AGENT_REPO" --agent-rev "$AGENT_REV" \
    --webui-repo "$WEBUI_REPO" --webui-rev "$WEBUI_REV" \
    --moss-repo "$MOSS_REPO" --moss-rev "$MOSS_REV" \
    --builder-repo "$BUILDER_REPO" --builder-rev "$BUILDER_REV" \
    --receipt "$receipt"
}

(
  cd "$tmp"
  run_builder "$tmp/receipt.json"
)
"$JQ_BIN" -e \
  --arg image "$IMAGE" --arg agent "$AGENT_REV" --arg webui "$WEBUI_REV" --arg moss "$MOSS_REV" --arg moss_tree "$MOSS_TREE" --arg builder "$BUILDER_REV" --arg provenance "$BASE_PROVENANCE_SHA" '
    .schema_version == 3 and .image_id == $image and .base_provenance_receipt_sha256 == $provenance
    and .sources.hermes_agent.commit == $agent and .sources.hermes_webui.commit == $webui
    and .sources.moss == {commit:$moss,tree:$moss_tree} and .sources.builder.commit == $builder
    and (.sources.hermes_agent.archive_sha256 | length) == 64 and (.sources.hermes_agent.marker_sha256 | length) == 64
    and (.sources.hermes_webui.archive_sha256 | length) == 64 and (.sources.hermes_webui.marker_sha256 | length) == 64
    and .production_lifecycle == false
  ' "$tmp/receipt.json" >/dev/null
[[ ! $(find "$tmp/fake-state/aliases" -type f -print -quit) ]]
[[ $(wc -l <"$tmp/fake-state/tagged.log") -eq 1 && $(wc -l <"$tmp/fake-state/removed.log") -eq 1 ]]

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

# Pinned receipt byte tamper and semantically wrong but re-sealed provenance both fail.
cp "$tmp/base-provenance.json" "$tmp/base-provenance-tampered.json"
printf ' ' >>"$tmp/base-provenance-tampered.json"
set +e
out=$(run_builder "$tmp/provenance-byte.json" "$tmp/base-provenance-tampered.json" "$BASE_PROVENANCE_SHA" 2>&1); rc=$?
set -e
[[ $rc -ne 0 && $out == *'base provenance receipt checksum mismatch'* ]]
printf '{"schema":"the-ai-crowd.moss-base-provenance.v1","base_image_id":"%s","moss":{"commit":"%s","tree":"%s"}}\n' \
  "$OTHER" "$MOSS_REV" "$MOSS_TREE" >"$tmp/base-provenance-wrong.json"
wrong_sha=$(sha256sum "$tmp/base-provenance-wrong.json" | cut -d' ' -f1)
set +e
out=$(run_builder "$tmp/provenance-semantic.json" "$tmp/base-provenance-wrong.json" "$wrong_sha" 2>&1); rc=$?
set -e
[[ $rc -ne 0 && $out == *'base provenance does not match image or resolved Moss source'* ]]
ln -s "$tmp/base-provenance.json" "$tmp/base-provenance-link.json"
set +e
out=$(run_builder "$tmp/provenance-link.json" "$tmp/base-provenance-link.json" "$BASE_PROVENANCE_SHA" 2>&1); rc=$?
set -e
[[ $rc -ne 0 && $out == *'base provenance receipt must be a regular non-symlink file'* ]]

# A pre-existing alias is neither overwritten nor removed.
before_tags=$(wc -l <"$tmp/fake-state/tagged.log")
before_removes=$(wc -l <"$tmp/fake-state/removed.log")
set +e
out=$(FAKE_PREEXIST_ALIAS=true run_builder "$tmp/preexisting.json" 2>&1); rc=$?
set -e
[[ $rc -eq 65 && $out == *'unique base alias unexpectedly pre-exists; refusing overwrite'* ]]
[[ $(wc -l <"$tmp/fake-state/tagged.log") -eq $before_tags ]]
[[ $(wc -l <"$tmp/fake-state/removed.log") -eq $before_removes ]]

# Concurrent executions receive distinct aliases and each removes only its own alias.
FAKE_BUILD_DELAY=0.2 run_builder "$tmp/concurrent-one.json" "$tmp/base-provenance.json" "$BASE_PROVENANCE_SHA" candidate:one >"$tmp/concurrent-one.log" 2>&1 &
pid_one=$!
FAKE_BUILD_DELAY=0.2 run_builder "$tmp/concurrent-two.json" "$tmp/base-provenance.json" "$BASE_PROVENANCE_SHA" candidate:two >"$tmp/concurrent-two.log" 2>&1 &
pid_two=$!
wait "$pid_one"
wait "$pid_two"
mapfile -t concurrent_tags < <(tail -n 2 "$tmp/fake-state/tagged.log" | sort -u)
[[ ${#concurrent_tags[@]} -eq 2 ]]
for alias in "${concurrent_tags[@]}"; do grep -Fxq "$alias" "$tmp/fake-state/removed.log"; done
[[ ! $(find "$tmp/fake-state/aliases" -type f -print -quit) ]]

set +e
out=$(PATH="$tmp/bin:$PATH" FAKE_BASE_IMAGE="$BASE" FAKE_OTHER_IMAGE="$OTHER" FAKE_IMAGE_ID="$IMAGE" \
  FAKE_STATE="$tmp/fake-state" FAKE_BASE_PROVENANCE_SHA="$BASE_PROVENANCE_SHA" \
  "$SCRIPT" --tag candidate:test --base-image "$BASE" \
  --base-provenance-receipt "$tmp/base-provenance.json" --base-provenance-sha256 "$BASE_PROVENANCE_SHA" \
  --agent-repo "$AGENT_REPO" --agent-rev 0000000000000000000000000000000000000000 \
  --webui-repo "$WEBUI_REPO" --webui-rev "$WEBUI_REV" \
  --moss-repo "$MOSS_REPO" --moss-rev "$MOSS_REV" \
  --builder-repo "$BUILDER_REPO" --builder-rev "$BUILDER_REV" \
  --receipt "$tmp/wrong-pin.json" 2>&1); rc=$?
set -e
[[ $rc -eq 65 && $out == *'Hermes Agent revision differs from the approved pin'* ]]
[[ ! -e $tmp/wrong-pin.json ]]
printf '%s\n' 'test-build-moss-integrated-release: PASS sealed-archives=2 causal-tamper=3 provenance-negatives=3 preexisting-alias=PASS concurrent-aliases=2 cleanup-owned-only=PASS write-once=PASS cwd-independent=PASS'
