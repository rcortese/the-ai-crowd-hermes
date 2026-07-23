#!/usr/bin/env bash
# Executable fake-first contract for the source-only candidate producer.
set -Eeuo pipefail
source_root=${1:?root required}
source_helper="$source_root/ops/scripts/build-moss-all-in-one-candidate.sh"
[[ -x $source_helper ]] || { printf '%s\n' 'missing build helper' >&2; exit 1; }

fail(){ printf 'BUILD CONTRACT ASSERT: %s\n' "$*" >&2; exit 1; }
fx=$(mktemp -d /tmp/moss-candidate-build-contract.XXXXXX)
trap 'if [[ ${HDDT_KEEP_FIXTURE:-0} == 1 ]]; then printf "BUILD_FIXTURE=%s\n" "$fx" >&2; else rm -rf -- "$fx"; fi' EXIT
repo="$fx/repo"; input="$fx/input"; bin="$fx/bin"; docker_log="$fx/docker.log"
mkdir -m 700 "$repo" "$input" "$bin"
printf '%s\n' '{"name":"fixture","version":"1.0.0"}' >"$input/package.json"
printf '%s\n' '{"name":"fixture","lockfileVersion":3}' >"$input/package-lock.json"

mkdir -p "$repo/ops/scripts" "$repo/ops/build-inputs" "$repo/ops/images" "$repo/ops/manifests"
cp -- "$source_helper" "$repo/ops/scripts/build-moss-all-in-one-candidate.sh"
chmod 755 "$repo/ops/scripts/build-moss-all-in-one-candidate.sh"
(
  cd "$input"
  sha256sum package.json package-lock.json
) >"$repo/ops/build-inputs/moss-clash-royale-war-bot.sha256"
printf '%s\n' 'FROM scratch' >"$repo/ops/images/Dockerfile.moss-all-in-one"
printf '%s\n' \
  ops/build-inputs/moss-clash-royale-war-bot.sha256 \
  ops/images/Dockerfile.moss-all-in-one \
  ops/manifests/moss-release-source-closure.paths \
  ops/scripts/build-moss-all-in-one-candidate.sh \
  source.txt | LC_ALL=C sort >"$repo/ops/manifests/moss-release-source-closure.paths"
printf '%s\n' 'fixture base' >"$repo/source.txt"
git -C "$repo" init -q -b main
git -C "$repo" config user.name fixture
git -C "$repo" config user.email fixture@example.invalid
git -C "$repo" add .
git -C "$repo" commit -q -m base
base_revision=$(git -C "$repo" rev-parse HEAD)
printf '%s\n' 'fixture source' >>"$repo/source.txt"
git -C "$repo" add source.txt
git -C "$repo" commit -q -m source
source_revision=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" checkout -q --orphan unrelated
git -C "$repo" rm -q -rf .
printf '%s\n' unrelated >"$repo/unrelated.txt"
git -C "$repo" add unrelated.txt
git -C "$repo" commit -q -m unrelated
nonancestor_revision=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" checkout -q main
git -C "$repo" remote add origin ssh://fixture/repo

image_id=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
cat >"$bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '<%s>' "$@" >>"${DOCKER_LOG:?}"
printf '\n' >>"$DOCKER_LOG"
case "${1:-} ${2:-}" in
  'build --pull=false') exit 0 ;;
  'image inspect')
    case ${5:-} in
      '{{.Id}}')
        if [[ ${3:-} == "${FIXTURE_BASE_ID:-}" ]]; then printf '%s\n' "${FIXTURE_BASE_ID:?}"; else printf '%s\n' "${FIXTURE_IMAGE_ID:?}"; fi
        ;;
      *) printf '%s\n' 'tag=fixture/moss:test image=sha256:bbbb created=fixed' ;;
    esac
    ;;
  'version --format') printf '%s\n' '{"Client":"fixture","Server":"fixture"}' ;;
  'buildx version') printf '%s\n' 'github.com/docker/buildx fixture' ;;
  *) exit 91 ;;
esac
DOCKER
cat >"$bin/date" <<'DATE'
#!/usr/bin/env bash
[[ $* == '-u +%s' ]] || exit 91
cat "${DATE_EPOCH_FILE:?}"
DATE
chmod 700 "$bin/docker" "$bin/date"
date_epoch_file="$fx/date.epoch"
printf '%s\n' 100 >"$date_epoch_file"
helper="$repo/ops/scripts/build-moss-all-in-one-candidate.sh"
base_image=sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd

env_common=(
  PATH="$bin:$PATH"
  CLASH_ROYALE_BUILD_INPUT_DIR="$input"
  MOSS_BASE_IMAGE="$base_image"
  DOCKER_LOG="$docker_log"
  FIXTURE_IMAGE_ID="$image_id"
  FIXTURE_BASE_ID="$base_image"
  DATE_EPOCH_FILE="$date_epoch_file"
)
run_with_base(){
  local receipts=$1 base=$2
  env "${env_common[@]}" BUILD_RECEIPT_ROOT="$receipts" HDDT_SOURCE_BASE_REVISION="$base" "$helper" fixture/moss:test
}
run_without_base(){
  local receipts=$1
  env -u HDDT_SOURCE_BASE_REVISION "${env_common[@]}" BUILD_RECEIPT_ROOT="$receipts" "$helper" fixture/moss:test
}
run_raw(){
  local receipts=$1
  shift
  env "$@" PATH="$bin:$PATH" DOCKER_LOG="$docker_log" FIXTURE_IMAGE_ID="$image_id" FIXTURE_BASE_ID="$base_image" DATE_EPOCH_FILE="$date_epoch_file" BUILD_RECEIPT_ROOT="$receipts" HDDT_SOURCE_BASE_REVISION="$base_revision" "$helper" fixture/moss:test
}
assert_no_effect(){
  local receipts=$1 label=$2
  [[ ! -s $docker_log ]] || fail "$label invoked docker"
  [[ ! -d $receipts ]] || ! compgen -G "$receipts/*.json" >/dev/null || fail "$label published receipt"
}
run_negative(){
  local label=$1 base=${2-__missing__} receipts rc=0
  receipts="$fx/receipts-$label"
  : >"$docker_log"
  set +e
  if [[ $base == __missing__ ]]; then
    run_without_base "$receipts" >"$fx/$label.out" 2>&1
  else
    run_with_base "$receipts" "$base" >"$fx/$label.out" 2>&1
  fi
  rc=$?
  set -e
  [[ $rc == 65 ]] || fail "$label expected rc=65 got rc=$rc"
  assert_no_effect "$receipts" "$label"
}

receipts="$fx/receipts-happy"
: >"$docker_log"
run_with_base "$receipts" "$base_revision" >"$fx/happy.out"
receipt="$receipts/sha256-${image_id#sha256:}.json"
[[ -f $receipt && ! -L $receipt ]] || fail 'happy receipt missing or unsafe'
jq -e --arg base "$base_revision" --arg source "$source_revision" \
  '.source_base_revision==$base and .source_revision==$source and .source_base_revision!=.source_revision' \
  "$receipt" >/dev/null || fail 'happy source-base binding mismatch'
mapfile -t expected_closure_paths <"$repo/ops/manifests/moss-release-source-closure.paths"
expected_closure=$(git -C "$repo" ls-tree -r --full-tree "$source_revision" -- "${expected_closure_paths[@]}" | sha256sum | cut -d' ' -f1)
jq -e --arg closure "$expected_closure" '.source_closure_sha256==$closure' "$receipt" >/dev/null || fail 'happy shared source closure mismatch'
cp -- "$receipt" "$fx/receipt.first"
expected_created_epoch=$(git -C "$repo" show -s --format=%ct "$source_revision")
jq -e --argjson expected "$expected_created_epoch" '.created_epoch==$expected' "$receipt" >/dev/null || fail 'receipt epoch is not source commit epoch'
printf '%s\n' 101 >"$date_epoch_file"
run_with_base "$receipts" "$base_revision" >"$fx/idempotent.out"
cmp -s "$fx/receipt.first" "$receipt" || fail 'idempotent receipt bytes changed'

jq '.created_epoch=101' "$receipt" >"$fx/divergent"
mv -- "$fx/divergent" "$receipt"; chmod 600 "$receipt"
set +e
run_with_base "$receipts" "$base_revision" >"$fx/divergent.out" 2>&1
rc=$?
set -e
[[ $rc == 65 ]] || fail "divergent receipt expected rc=65 got rc=$rc"
grep -Fq 'divergent or unsafe build receipt already exists' "$fx/divergent.out" || fail 'divergent receipt oracle missing'

run_negative missing
run_negative nonhex ABC
run_negative nonexistent 4444444444444444444444444444444444444444
run_negative equal "$source_revision"
run_negative nonancestor "$nonancestor_revision"

run_input_negative(){
  local label=$1
  shift
  local receipts="$fx/receipts-$label" rc=0
  : >"$docker_log"
  set +e
  run_raw "$receipts" "$@" >"$fx/$label.out" 2>&1
  rc=$?
  set -e
  [[ $rc == 65 ]] || fail "$label expected rc=65 got rc=$rc"
  assert_no_effect "$receipts" "$label"
}

run_input_negative missing-input MOSS_BASE_IMAGE="$base_image"
run_input_negative missing-base CLASH_ROYALE_BUILD_INPUT_DIR="$input"
run_input_negative mutable-base CLASH_ROYALE_BUILD_INPUT_DIR="$input" MOSS_BASE_IMAGE=fixture/base:mutable

for file in package.json package-lock.json; do
  cp -- "$input/$file" "$fx/$file.clean"
  printf '%s\n' tampered >>"$input/$file"
  run_input_negative "tampered-${file//./-}" CLASH_ROYALE_BUILD_INPUT_DIR="$input" MOSS_BASE_IMAGE="$base_image"
  mv -- "$fx/$file.clean" "$input/$file"
done

if [[ ${MOSS_BUILD_CONTRACT_MUTATION_CHILD:-0} != 1 ]]; then
  mutroot="$fx/mutroot"
  mkdir -p "$mutroot/ops/scripts"
  cp -- "$source_helper" "$mutroot/ops/scripts/build-moss-all-in-one-candidate.sh"
  mutant_helper="$mutroot/ops/scripts/build-moss-all-in-one-candidate.sh"
  mutant_tmp="$mutant_helper.tmp"
  checksum_anchors=0
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line == '  sha256sum -c "$CTX/$MANIFEST_REL"' ]]; then
      printf '%s\n' '  true # MUTANT: checksum verification omitted' >>"$mutant_tmp"
      ((checksum_anchors+=1))
    else
      printf '%s\n' "$line" >>"$mutant_tmp"
    fi
  done <"$mutant_helper"
  [[ $checksum_anchors == 1 ]] || fail 'checksum mutant anchor mismatch'
  mv -- "$mutant_tmp" "$mutant_helper"
  chmod 755 "$mutant_helper"
  set +e
  MOSS_BUILD_CONTRACT_MUTATION_CHILD=1 bash "$0" "$mutroot" >"$fx/checksum-mutant.out" 2>&1
  mutant_rc=$?
  set -e
  [[ $mutant_rc != 0 ]] || fail 'checksum-omission mutant survived'
  grep -Fq 'tampered-package-json expected rc=65 got rc=0' "$fx/checksum-mutant.out" || fail 'checksum-omission mutant lacked causal oracle'
fi

printf '%s\n' 'moss-candidate-build-contract: PASS real-git=true docker=fake source-base=true immutable-base=true checksum-bound=true checksum-mutant=RED idempotent=true negatives=10'
