#!/usr/bin/env bash
set -Eeuo pipefail
root=${1:?source root required}
patch_file="$root/ops/hermes-webui-overrides/moss-title-topic-priority.patch"
dockerfile="$root/ops/images/Dockerfile.moss-all-in-one"
fail(){ printf 'TITLE CONTRACT ASSERT: %s\n' "$*" >&2; exit 1; }
[[ -f $patch_file && -f $dockerfile ]] || fail 'required source files missing'
grep -Fq 'Identify the main topic and substantive intent.' "$patch_file" || fail 'substantive-topic rule missing'
grep -Fq 'Do not prioritize method, format, tool, role, audit, review, handoff, or process step' "$patch_file" || fail 'method-deprioritization rule missing'
grep -Fq '&& git apply /tmp/moss-title-topic-priority.patch' "$dockerfile" || fail 'title patch application missing'
grep -Fq 'from api.streaming import _title_prompts' "$dockerfile" || fail 'patched title helper is not imported during build'
grep -Fq 'assert len(prompts) == 2' "$dockerfile" || fail 'title prompt cardinality assertion missing'
grep -Fq 'assert any("main topic and substantive intent" in p for p in prompts)' "$dockerfile" || fail 'substantive-topic build assertion missing'
grep -Fq 'assert all("Do not prioritize method, format, tool, role, audit, review, handoff, or process step" in p for p in prompts)' "$dockerfile" || fail 'method-deprioritization build assertion missing'
printf '%s\n' 'moss-title-topic-contract: PASS patch-applied=true helper-imported=true behavioral-assertions=true'

if [[ ${MOSS_TITLE_CONTRACT_CHILD:-0} != 1 ]]; then
  fx=$(mktemp -d /tmp/moss-title-contract.XXXXXX)
  trap 'rm -rf -- "$fx"' EXIT
  mutate_and_expect_red(){
    local label=$1 target=$2 old=$3 new=$4
    local mutroot="$fx/$label" body rc=0 out="$fx/$label.out"
    mkdir -p "$mutroot/ops/hermes-webui-overrides" "$mutroot/ops/images"
    cp -- "$patch_file" "$mutroot/ops/hermes-webui-overrides/moss-title-topic-priority.patch"
    cp -- "$dockerfile" "$mutroot/ops/images/Dockerfile.moss-all-in-one"
    body=$(<"$mutroot/$target")
    [[ $body == *"$old"* ]] || fail "$label mutant anchor missing"
    printf '%s' "${body/"$old"/"$new"}" >"$mutroot/$target"
    set +e
    MOSS_TITLE_CONTRACT_CHILD=1 bash "$0" "$mutroot" >"$out" 2>&1
    rc=$?
    set -e
    [[ $rc != 0 ]] || fail "$label mutant survived"
  }
  mutate_and_expect_red topic-rule ops/hermes-webui-overrides/moss-title-topic-priority.patch 'Identify the main topic and substantive intent.' 'Prioritize the workflow method.'
  mutate_and_expect_red patch-apply ops/images/Dockerfile.moss-all-in-one '&& git apply /tmp/moss-title-topic-priority.patch' '&& true # MUTANT patch omitted'
  mutate_and_expect_red behavior-check ops/images/Dockerfile.moss-all-in-one 'from api.streaming import _title_prompts' 'from api.streaming import _title_language_mismatch'
  printf '%s\n' 'moss-title-topic-mutations: PASS total=3 causal-red=true'
fi
