#!/usr/bin/env bash
# Causal fake-Docker contract for Roy's local base-candidate provenance.
set -Eeuo pipefail
root=${1:?root required}
source_builder="$root/ops/scripts/build-roy-all-in-one-candidate.sh"
[[ -x $source_builder ]] || { printf '%s\n' 'missing Roy candidate builder' >&2; exit 1; }
fail(){ printf 'ROY BUILD CONTRACT ASSERT: %s\n' "$*" >&2; exit 1; }
tmp_root=${TMPDIR:-/tmp}; [[ -d $tmp_root ]] || tmp_root=/tmp
export TMPDIR="$tmp_root"
fx=$(mktemp -d "$tmp_root/roy-candidate-build-contract.XXXXXX")
trap 'rm -rf -- "$fx"' EXIT
repo="$fx/repo"; bin="$fx/bin"; docker_log="$fx/docker.log"
mkdir -m 700 "$repo" "$bin"
mkdir -p "$repo/ops/scripts" "$repo/ops/images" "$repo/ops/manifests"
cp -- "$source_builder" "$repo/ops/scripts/build-roy-all-in-one-candidate.sh"
cp -- "$root/ops/scripts/verify-hermes-webui-api-server-contract.py" "$repo/ops/scripts/verify-hermes-webui-api-server-contract.py"
cp -- "$root/ops/images/roy-all-in-one.supervisor.conf" "$repo/ops/images/roy-all-in-one.supervisor.conf"
cp -- "$root/ops/manifests/protected-hermes-a2a-base.lock.json" "$repo/ops/manifests/protected-hermes-a2a-base.lock.json"
printf '%s\n' 'ARG ROY_BASE_IMAGE' 'FROM ${ROY_BASE_IMAGE}' >"$repo/ops/images/Dockerfile.roy-all-in-one"
git -C "$repo" init -q -b main
git -C "$repo" config user.name fixture
git -C "$repo" config user.email fixture@example.invalid
git -C "$repo" add . && git -C "$repo" commit -qm fixture
git -C "$repo" remote add origin ssh://fixture/roy
base_id=sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
other_id=sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
image_id=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
candidate_ref=the-ai-crowd/roy:base-candidate-a2bdd
expected_commit=a2bddaf9921c8b8b10f96e188bb61f0a33d9bfc5
expected_tree=9f483dffbf04b33efb4e7bffd3a0a7247f82e223
expected_hermes_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["protected_base"]["image_id"])' "$root/ops/manifests/protected-hermes-a2a-base.lock.json")
expected_hermes_source=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["protected_base"]["source_revision"])' "$root/ops/manifests/protected-hermes-a2a-base.lock.json")
cat >"$bin/jq" <<'JQ'
#!/usr/bin/env python3
import json, sys
args = sys.argv[1:]
if '-er' in args:
    expression, path = args[args.index('-er') + 1:args.index('-er') + 3]
    data = json.load(open(path))
    print(data['protected_base']['image_id' if 'image_id' in expression else 'source_revision'])
    sys.exit(0)
if '-ncS' in args:
    values = {}
    i = args.index('-ncS') + 1
    while i < len(args) and args[i] in ('--arg', '--argjson'):
        key, value = args[i + 1:i + 3]
        values[key] = json.loads(value) if args[i] == '--argjson' else value
        i += 3
    print(json.dumps(values, sort_keys=True, separators=(',', ':')))
    sys.exit(0)
if '-ceS' in args:
    print(json.dumps(json.load(open(args[-1])), sort_keys=True, separators=(',', ':')))
    sys.exit(0)
raise SystemExit('fixture jq only supports receipt serialization and validation')
JQ
cat >"$bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '<%s>' "$@" >>"${DOCKER_LOG:?}"; printf '\n' >>"$DOCKER_LOG"
mutate_prebuild(){
  case "${PREBUILD_MUTATION:-}" in
    tamper) printf '%s\n' '{"status":"TAMPERED"}' >"${PREBUILD_RECEIPT_PATH:?}" ;;
    remove) rm -f -- "${PREBUILD_RECEIPT_PATH:?}" ;;
    '') : ;;
    *) exit 92 ;;
  esac
}
case "${1:-} ${2:-}" in
  'build --pull=false')
    [[ ${PREBUILD_MUTATION_AT:-tag} == build ]] && mutate_prebuild
    args=("$@")
    for ((i = 0; i < ${#args[@]}; i++)); do
      if [[ ${args[i]} == --label && ${args[i + 1]:-} == the-ai-crowd.prebuild-receipt-sha256=* ]]; then
        printf '%s\n' "${args[i + 1]#the-ai-crowd.prebuild-receipt-sha256=}" >"${FAKE_FINAL_PREBUILD_LABEL:?}"
      fi
    done
    : >"${FAKE_BUILT:?}"
    exit 0 ;;
  'image tag')
    [[ ${PREBUILD_MUTATION_AT:-tag} == tag ]] && mutate_prebuild
    exit 0 ;;
  'image inspect')
    target=${3:-}; format=${5:-}
    if [[ $target == "the-ai-crowd/roy-build-base:${BASE_ID#sha256:}" && ${PREBUILD_MUTATION_AT:-tag} == alias-inspect ]]; then
      mutate_prebuild
    fi
    case "$format" in
      '')
        [[ $target == "${TARGET_TAG:?}" && ${FAKE_MODE:-happy} == target-exists ]] && { printf '%s\n' "${IMAGE_ID:?}"; exit 0; }
        exit 1 ;;
      '{{.Id}}')
        if [[ $target == "${ROY_BASE_CANDIDATE_REF:?}" ]]; then
          [[ ${FAKE_MODE:-happy} == wrong-ref ]] && printf '%s\n' "${OTHER_BASE_ID:?}" || printf '%s\n' "${BASE_ID:?}"
        elif [[ $target == "${TARGET_TAG:?}" ]]; then
          if [[ ${FAKE_MODE:-happy} == target-exists || -e ${FAKE_BUILT:?} ]]; then printf '%s\n' "${IMAGE_ID:?}"; else exit 1; fi
        elif [[ $target == "${BASE_ID:?}" || $target == "the-ai-crowd/roy-build-base:${BASE_ID#sha256:}" ]]; then printf '%s\n' "${BASE_ID:?}"
        else printf '%s\n' "${IMAGE_ID:?}"; fi ;;
      *'the-ai-crowd.source-commit'*) [[ ${FAKE_MODE:-happy} == label-mismatch ]] && printf '%s\n' deadbeef || printf '%s\n' "${EXPECTED_COMMIT:?}" ;;
      *'the-ai-crowd.source-tree'*) [[ ${FAKE_MODE:-happy} == label-mismatch ]] && printf '%s\n' deadbeef || printf '%s\n' "${EXPECTED_TREE:?}" ;;
      *'the-ai-crowd.hermes-base-id'*) printf '%s\n' "${EXPECTED_HERMES_ID:?}" ;;
      *'the-ai-crowd.hermes-base-source-revision'*) [[ ${FAKE_MODE:-happy} == wrong-base-source ]] && printf '%s\n' deadbeef || printf '%s\n' "${EXPECTED_HERMES_SOURCE:?}" ;;
      *'the-ai-crowd.prebuild-receipt-sha256'*)
        [[ $target == "${TARGET_TAG:?}" && -e ${FAKE_BUILT:?} ]] || exit 1
        [[ ${FAKE_MODE:-happy} == prebuild-label-mismatch ]] && printf '%064d\n' 0 || cat "${FAKE_FINAL_PREBUILD_LABEL:?}" ;;
      *) exit 91 ;;
    esac ;;
  *) exit 91 ;;
esac
DOCKER
chmod 700 "$bin/docker" "$bin/jq"
helper="$repo/ops/scripts/build-roy-all-in-one-candidate.sh"
common=(PATH="$bin:$PATH" DOCKER_LOG="$docker_log" FAKE_BUILT="$fx/built" FAKE_FINAL_PREBUILD_LABEL="$fx/final-prebuild-label" TARGET_TAG=fixture/roy:test BASE_ID="$base_id" OTHER_BASE_ID="$other_id" IMAGE_ID="$image_id" EXPECTED_COMMIT="$expected_commit" EXPECTED_TREE="$expected_tree" EXPECTED_HERMES_ID="$expected_hermes_id" EXPECTED_HERMES_SOURCE="$expected_hermes_source" ROY_BASE_IMAGE="$base_id" ROY_WEBUI_REPO=https://fixture.invalid/webui ROY_WEBUI_REV=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ROY_WEBUI_TREE=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ROY_WEBUI_ARCHIVE_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ROY_WEBUI_ARCHIVE_SIZE=123)
run(){ local receipts=$1; shift; local prebuild="$receipts/prebuild-$(printf '%s' fixture/roy:test | sha256sum | cut -d' ' -f1).json"; env "${common[@]}" ROY_BASE_CANDIDATE_REF="$candidate_ref" PREBUILD_RECEIPT_PATH="$prebuild" "$@" BUILD_RECEIPT_ROOT="$receipts" "$helper" fixture/roy:test; }
assert_no_receipt(){ local receipts=$1 label=$2; [[ ! -d $receipts ]] || ! compgen -G "$receipts/*.json" >/dev/null || fail "$label published a receipt"; }
receipts="$fx/receipts-happy"; : >"$docker_log"
run "$receipts" >"$fx/happy.out"
receipt="$receipts/sha256-${image_id#sha256:}.json"
[[ -f $receipt && ! -L $receipt ]] || fail 'happy receipt missing'
python3 - "$receipt" "$candidate_ref" "$base_id" "$expected_commit" "$expected_tree" "$expected_hermes_id" "$expected_hermes_source" "$fx/final-prebuild-label" <<'PY'
import hashlib, json, sys
receipt, ref, image, commit, tree, hermes_id, hermes_source, final_label = sys.argv[1:]
data = json.load(open(receipt))
expected = {"roy_base_candidate_ref": ref, "roy_base_image_id": image, "roy_base_source_commit": commit, "roy_base_source_tree": tree, "roy_base_hermes_base_id": hermes_id, "roy_base_hermes_base_source_revision": hermes_source}
assert all(data.get(key) == value for key, value in expected.items())
assert data["webui_tree"] == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
assert data["webui_archive_size"] == "123"
prebuild_path = data["prebuild_receipt"]
prebuild_bytes = open(prebuild_path, "rb").read()
assert data["prebuild_receipt_sha256"] == hashlib.sha256(prebuild_bytes).hexdigest()
assert open(final_label).read().strip() == data["prebuild_receipt_sha256"]
assert data["prebuild_receipt_payload"] == json.loads(prebuild_bytes)
assert data["prebuild_receipt_payload"]["status"] == "ROY_PREBUILD_ADMITTED"
PY
grep -Fq "<--label><the-ai-crowd.roy-base-candidate-ref=$candidate_ref>" "$docker_log" || fail 'final image missed candidate-ref label'
grep -Fq "<--label><the-ai-crowd.roy-base-source-commit=$expected_commit>" "$docker_log" || fail 'final image missed base source label'
assert_no_alias_or_build(){ local label=$1; ! grep -Fq '<image><tag>' "$docker_log" || fail "$label created alias"; ! grep -Fq '<build><--pull=false>' "$docker_log" || fail "$label invoked build"; }
negative(){ local label=$1 mode=$2; shift 2; local receipts="$fx/receipts-$label" rc=0; : >"$docker_log"; rm -f "$fx/built"; set +e; run "$receipts" FAKE_MODE="$mode" "$@" >"$fx/$label.out" 2>&1; rc=$?; set -e; [[ $rc == 65 ]] || fail "$label expected rc=65, got $rc"; assert_no_receipt "$receipts" "$label"; assert_no_alias_or_build "$label"; }
negative ref-wrong-id wrong-ref
negative label-mismatch label-mismatch
negative wrong-base-source wrong-base-source
negative target-exists target-exists
final_prebuild_label_mismatch(){ local receipts="$fx/receipts-final-prebuild-label-mismatch" rc=0; : >"$docker_log"; rm -f "$fx/built" "$fx/final-prebuild-label"; set +e; run "$receipts" FAKE_MODE=prebuild-label-mismatch >"$fx/final-prebuild-label-mismatch.out" 2>&1; rc=$?; set -e; [[ $rc == 65 ]] || fail "final-prebuild-label-mismatch expected rc=65, got $rc"; [[ -e "$fx/built" ]] || fail 'final-prebuild-label-mismatch did not invoke fake build'; [[ ! -e "$receipts/sha256-${image_id#sha256:}.json" ]] || fail 'final-prebuild-label-mismatch published final receipt'; }
final_prebuild_label_mismatch
prebuild_tamper_or_remove(){ local label=$1 mutation=$2 receipts rc=0; receipts="$fx/receipts-$label"; : >"$docker_log"; rm -f "$fx/built"; set +e; run "$receipts" PREBUILD_MUTATION="$mutation" >"$fx/$label.out" 2>&1; rc=$?; set -e; [[ $rc == 65 ]] || fail "$label expected rc=65, got $rc"; [[ -f "$receipts/prebuild-$(printf '%s' fixture/roy:test | sha256sum | cut -d' ' -f1).json" || $mutation == remove ]] || fail "$label did not reach prebuild admission"; [[ ! -e "$receipts/sha256-${image_id#sha256:}.json" ]] || fail "$label published final receipt"; ! grep -Fq '<build><--pull=false>' "$docker_log" || fail "$label invoked build"; }
prebuild_tamper_or_remove prebuild-tampered tamper
prebuild_tamper_or_remove prebuild-removed remove
prebuild_tamper_or_remove_after_alias_inspect(){ local label=$1 mutation=$2 receipts rc=0; receipts="$fx/receipts-$label"; : >"$docker_log"; rm -f "$fx/built"; set +e; run "$receipts" PREBUILD_MUTATION="$mutation" PREBUILD_MUTATION_AT=alias-inspect >"$fx/$label.out" 2>&1; rc=$?; set -e; [[ $rc == 65 ]] || fail "$label expected rc=65, got $rc"; [[ ! -e "$receipts/sha256-${image_id#sha256:}.json" ]] || fail "$label published final receipt"; ! grep -Fq '<build><--pull=false>' "$docker_log" || fail "$label invoked build"; }
prebuild_tamper_or_remove_after_alias_inspect prebuild-tampered-after-alias-inspect tamper
prebuild_tamper_or_remove_after_alias_inspect prebuild-removed-after-alias-inspect remove
prebuild_tamper_or_remove_during_build(){ local label=$1 mutation=$2 receipts rc=0; receipts="$fx/receipts-$label"; : >"$docker_log"; rm -f "$fx/built"; set +e; run "$receipts" PREBUILD_MUTATION="$mutation" PREBUILD_MUTATION_AT=build >"$fx/$label.out" 2>&1; rc=$?; set -e; [[ $rc == 65 ]] || fail "$label expected rc=65, got $rc"; [[ -e "$fx/built" ]] || fail "$label did not invoke fake build"; [[ ! -e "$receipts/sha256-${image_id#sha256:}.json" ]] || fail "$label published final receipt"; }
prebuild_tamper_or_remove_during_build prebuild-tampered-during-build tamper
prebuild_tamper_or_remove_during_build prebuild-removed-during-build remove
receipts="$fx/receipts-existing-prebuild"; mkdir -p "$receipts"; : >"$receipts/prebuild-$(printf '%s' fixture/roy:test | sha256sum | cut -d' ' -f1).json"; : >"$docker_log"; rm -f "$fx/built"; set +e; run "$receipts" >"$fx/existing-prebuild.out" 2>&1; rc=$?; set -e; [[ $rc == 65 ]] || fail "existing-prebuild expected rc=65, got $rc"; assert_no_alias_or_build existing-prebuild
receipts="$fx/receipts-missing-tree"; : >"$docker_log"; rm -f "$fx/built"; set +e; env "${common[@]}" ROY_WEBUI_TREE= ROY_BASE_CANDIDATE_REF="$candidate_ref" BUILD_RECEIPT_ROOT="$receipts" "$helper" fixture/roy:test >"$fx/missing-tree.out" 2>&1; rc=$?; set -e; [[ $rc == 65 ]] || fail "missing-tree expected rc=65, got $rc"; assert_no_receipt "$receipts" missing-tree; assert_no_alias_or_build missing-tree
receipts="$fx/receipts-missing-ref"; : >"$docker_log"; set +e; env -u ROY_BASE_CANDIDATE_REF "${common[@]}" BUILD_RECEIPT_ROOT="$receipts" "$helper" fixture/roy:test >"$fx/missing-ref.out" 2>&1; rc=$?; set -e; [[ $rc == 65 ]] || fail "missing-ref expected rc=65, got $rc"; assert_no_receipt "$receipts" missing-ref; [[ ! -s $docker_log ]] || fail 'missing-ref invoked docker'
printf '%s\n' 'roy-all-in-one-candidate-build-contract: PASS fake-docker=true admission=true webui-tree=true provenance=true negatives=14 no-alias-or-receipt-on-admission-failure=true'
