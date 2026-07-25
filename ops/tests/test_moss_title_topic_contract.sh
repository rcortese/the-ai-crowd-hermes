#!/usr/bin/env bash
set -Eeuo pipefail
root=${1:?source root required}
dockerfile="$root/ops/images/Dockerfile.moss-all-in-one"
expected_rev=da2301e9f9c24509224646588a92c359c4e734d6
fail(){ printf 'TITLE CONTRACT ASSERT: %s\n' "$*" >&2; exit 1; }
[[ -f $dockerfile && ! -L $dockerfile ]] || fail 'Dockerfile missing or unsafe'
grep -Fq "ARG HERMES_WEBUI_REV=$expected_rev" "$dockerfile" || fail 'reviewed WebUI revision pin missing'
grep -Fq "test \"\$(git rev-parse HEAD)\" = \"$expected_rev\"" "$dockerfile" || fail 'checked-out WebUI revision assertion missing'
grep -Fq '&& test -z "$(git status --porcelain)"' "$dockerfile" || fail 'clean fork checkout assertion missing'
if grep -Fq 'git apply' "$dockerfile"; then fail 'obsolete local WebUI patch application remains'; fi
if grep -Fq 'COPY ops/hermes-webui-overrides/' "$dockerfile"; then fail 'obsolete local WebUI patch copy remains'; fi
for patch in \
  moss-agent-health-auth.patch \
  moss-profile-selector-order.patch \
  moss-remote-proxy-routing.patch \
  moss-terminal-state-false-no-response.patch \
  moss-service-session-launch.patch \
  moss-title-topic-priority.patch
do
  [[ ! -e "$root/ops/hermes-webui-overrides/$patch" ]] || fail "obsolete patch remains: $patch"
done
grep -Fq 'from api.streaming import _title_prompts' "$dockerfile" || fail 'title helper is not imported during build'
grep -Fq 'assert len(prompts) == 2' "$dockerfile" || fail 'title prompt cardinality assertion missing'
grep -Fq 'assert any("main topic and substantive intent" in p for p in prompts)' "$dockerfile" || fail 'substantive-topic build assertion missing'
grep -Fq 'assert all("Do not prioritize method, format, tool, role, audit, review, handoff, or process step" in p for p in prompts)' "$dockerfile" || fail 'method-deprioritization build assertion missing'
grep -Fq 'assert all("Match the language of the user question." in p for p in prompts)' "$dockerfile" || fail 'language-preservation build assertion missing'
grep -Fq 'tests/test_ai_crowd_title_topic_priority.py' "$dockerfile" || fail 'fork title regression test missing from build'
printf '%s\n' 'moss-title-topic-contract: PASS fork-pinned=true local-patches=absent behavioral-assertions=true'

if [[ ${MOSS_TITLE_CONTRACT_CHILD:-0} != 1 ]]; then
  fx=$(mktemp -d /tmp/moss-title-contract.XXXXXX)
  trap 'rm -rf -- "$fx"' EXIT
  mutate_and_expect_red(){
    local label=$1 old=$2 new=$3
    local mutroot="$fx/$label" body rc=0 out="$fx/$label.out"
    mkdir -p "$mutroot/ops/images" "$mutroot/ops/hermes-webui-overrides"
    cp -- "$dockerfile" "$mutroot/ops/images/Dockerfile.moss-all-in-one"
    body=$(<"$mutroot/ops/images/Dockerfile.moss-all-in-one")
    [[ $body == *"$old"* ]] || fail "$label mutant anchor missing"
    printf '%s' "${body/"$old"/"$new"}" >"$mutroot/ops/images/Dockerfile.moss-all-in-one"
    set +e
    MOSS_TITLE_CONTRACT_CHILD=1 bash "$0" "$mutroot" >"$out" 2>&1
    rc=$?
    set -e
    [[ $rc != 0 ]] || fail "$label mutant survived"
  }
  mutate_and_expect_red revision-pin "ARG HERMES_WEBUI_REV=$expected_rev" 'ARG HERMES_WEBUI_REV=9099d8e72c844cc6cd2acb80e6fbddd2e305aa03'
  mutate_and_expect_red topic-rule 'assert any("main topic and substantive intent" in p for p in prompts)' 'assert any("workflow method" in p for p in prompts)'
  mutate_and_expect_red language-rule 'assert all("Match the language of the user question." in p for p in prompts)' 'assert all("Use English." in p for p in prompts)'
  mutate_and_expect_red clean-source '&& test -z "$(git status --porcelain)"' '&& git apply /tmp/reintroduced.patch'
  printf '%s\n' 'moss-title-topic-mutations: PASS total=4 causal-red=true'
fi
