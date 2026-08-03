#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/ops/scripts/build-moss-source-bound-base.sh"
DOCKERFILE="$ROOT/ops/images/Dockerfile.moss-source-bound-base"
MOSS_REPO=${1:?usage: $0 MOSS_REPO [BUILDER_REV [BUILDER_REPO]]}
BUILDER_REV=${2:-$(git -C "$ROOT" rev-parse HEAD)}
BUILDER_REPO=${3:-$ROOT}
readonly MOSS_REV=321f1158b2c360a895c4a1679c000aa4ff3b7a9d
readonly MOSS_TREE=b2fa360209db0da9fe2e69a916a81ab7d00d98cf
readonly BASE=sha256:f7db73a38d6c82f0534fe9b638f4891972a7714cd2eea0497ab84d5c2c53cc3a
readonly IMAGE=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

test "$(git -C "$MOSS_REPO" rev-parse "$MOSS_REV^{commit}")" = "$MOSS_REV"
test "$(git -C "$MOSS_REPO" rev-parse "$MOSS_REV^{tree}")" = "$MOSS_TREE"
bash -n "$SCRIPT"
grep -Fq "readonly MOSS_PIN=$MOSS_REV" "$SCRIPT"
grep -Fq 'running base builder differs from queued builder commit' "$SCRIPT"
grep -Fq 'org.the-ai-crowd.moss-source-binding-kind="archived-git-source"' "$DOCKERFILE"
grep -Fq 'org.the-ai-crowd.base-runtime-provenance' "$DOCKERFILE"
grep -Fq 'sealed Moss archive checksum mismatch' "$DOCKERFILE"
grep -Fq 'tar -xf /tmp/sealed-moss/source.tar -C /opt/the-ai-crowd/source/moss' "$DOCKERFILE"
grep -Fq 'test ! -e /opt/the-ai-crowd/source/moss/.git' "$DOCKERFILE"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/state/aliases"
cat >"$tmp/bin/docker" <<'FAKE'
#!/usr/bin/env bash
set -Eeuo pipefail
BASE=${FAKE_BASE_IMAGE:?}; IMAGE=${FAKE_IMAGE_ID:?}; STATE=${FAKE_STATE:?}
key(){ printf %s "$1" | sha256sum | cut -d' ' -f1; }
if [[ ${1:-} == image && ${2:-} == inspect ]]; then
  ref=${3:-}; formatted=false; [[ ${4:-} == --format ]] && formatted=true
  if [[ $ref == "$BASE" ]]; then
    [[ $formatted == true ]] && echo "$BASE" || printf '[{"Id":"%s","RootFS":{"Layers":["base-layer"]}}]\n' "$BASE"
    exit 0
  fi
  if [[ $ref == "$IMAGE" || $ref == candidate:* ]]; then
    [[ $formatted == true ]] && echo "$IMAGE" || printf '[{"Id":"%s","RootFS":{"Layers":["base-layer","source-layer"]}}]\n' "$IMAGE"
    exit 0
  fi
  if [[ $ref == the-ai-crowd/moss-runtime-base:* ]]; then file="$STATE/aliases/$(key "$ref")"; [[ -f $file ]] || exit 1; cat "$file"; exit 0; fi
  exit 1
fi
if [[ ${1:-} == image && ${2:-} == tag ]]; then file="$STATE/aliases/$(key "${4:?}")"; printf '%s\n' "$BASE" >"$file"; exit 0; fi
[[ ${1:-} == build ]] || exit 90
shift; declare -A arg ctx; main=; iidfile=
while (($#)); do case "$1" in --build-arg) k=${2%%=*}; arg[$k]=${2#*=}; shift 2;; --build-context) k=${2%%=*}; ctx[$k]=${2#*=}; shift 2;; --iidfile) iidfile=${2:?}; shift 2;; --file|--tag) shift 2;; --pull=false) shift;; *) main=$1; shift;; esac; done
[[ -d $main && ! -e $main/.git ]]
c=${ctx[moss_source]:?}; [[ -f $c/source.tar && -f $c/source.marker && ! -e $c/.git ]]
[[ $(sha256sum "$c/source.tar" | cut -d' ' -f1) == ${arg[MOSS_SOURCE_ARCHIVE_SHA256]} ]]
expected=$(printf 'schema_version=1\ncommit=%s\ntree=%s\narchive_sha256=%s\n' "${arg[MOSS_SOURCE_REV]}" "${arg[MOSS_SOURCE_TREE]}" "${arg[MOSS_SOURCE_ARCHIVE_SHA256]}")
[[ $(<"$c/source.marker") == "$expected" ]]
[[ $(sha256sum "$c/source.marker" | cut -d' ' -f1) == ${arg[MOSS_SOURCE_MARKER_SHA256]} ]]
[[ ${arg[MOSS_RUNTIME_BASE_ID]} == "$BASE" ]]
[[ ${arg[MOSS_SOURCE_REV]} == 321f1158b2c360a895c4a1679c000aa4ff3b7a9d ]]
[[ ${arg[MOSS_SOURCE_TREE]} == b2fa360209db0da9fe2e69a916a81ab7d00d98cf ]]
mkdir "$c/out"; tar -xf "$c/source.tar" -C "$c/out"; [[ ! -e $c/out/.git ]]; find "$c/out" -type f -print -quit | grep -q .
printf '%s' "$IMAGE" >"${iidfile:?}"
FAKE
chmod 0755 "$tmp/bin/docker"
run(){ PATH="$tmp/bin:$PATH" FAKE_BASE_IMAGE=$BASE FAKE_IMAGE_ID=$IMAGE FAKE_STATE="$tmp/state" "$SCRIPT" --tag candidate:test --runtime-base-image "$BASE" --moss-repo "$MOSS_REPO" --moss-rev "$MOSS_REV" --builder-repo "$BUILDER_REPO" --builder-rev "$BUILDER_REV" --receipt "$1"; }
(cd "$tmp"; run "$tmp/receipt.json")
python3 - "$tmp/receipt.json" "$IMAGE" "$MOSS_REV" "$MOSS_TREE" <<'PY'
import json,sys
p,image,commit,tree=sys.argv[1:]
d=json.load(open(p))
assert d=={"schema":"the-ai-crowd.moss-base-provenance.v1","base_image_id":image,"moss":{"commit":commit,"tree":tree}}
PY
[[ $(find "$tmp/state/aliases" -type f | wc -l) -eq 1 ]]
set +e; out=$(run "$tmp/receipt.json" 2>&1); rc=$?; set -e
[[ $rc -eq 65 && $out == *'receipt already exists (write-once)'* ]]
set +e
out=$(PATH="$tmp/bin:$PATH" FAKE_BASE_IMAGE=$BASE FAKE_IMAGE_ID=$IMAGE FAKE_STATE="$tmp/state" "$SCRIPT" --tag candidate:test --runtime-base-image "$BASE" --moss-repo "$MOSS_REPO" --moss-rev 0000000000000000000000000000000000000000 --builder-repo "$BUILDER_REPO" --builder-rev "$BUILDER_REV" --receipt "$tmp/wrong.json" 2>&1); rc=$?
set -e
[[ $rc -eq 65 && $out == *'Moss revision differs from the approved pin'* && ! -e $tmp/wrong.json ]]
printf '%s\n' 'test-build-moss-source-bound-base: PASS sealed-archive=1 git-free=PASS runtime-provenance-separated=PASS iidfile-bound=PASS rootfs-prefix=PASS receipt=closed/write-once wrong-pin=PASS resolver-alias-retained=PASS'
