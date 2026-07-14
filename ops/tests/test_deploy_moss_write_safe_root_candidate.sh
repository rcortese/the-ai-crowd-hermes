#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
runner="$repo/ops/scripts/deploy-moss-write-safe-root-candidate.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
commit=1111111111111111111111111111111111111111
old_image=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
candidate="the-ai-crowd/moss-all-in-one:write-safe-root-$commit"
candidate_image_id=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
CALL_LOG="$tmp/calls"

make_fakes() {
  mkdir -p "$tmp/fakebin" "$tmp/archive/ops/images" "$tmp/buildtmp"
  printf 'tracked archive fixture\n' >"$tmp/archive/README.md"
  printf 'base Dockerfile fixture\n' >"$tmp/archive/ops/images/Dockerfile.moss"
  printf 'all-in-one Dockerfile fixture\n' >"$tmp/archive/ops/images/Dockerfile.moss-all-in-one"
  cat >"$tmp/fakebin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'git %s\n' "$*" >>"$CALL_LOG"
if [[ $* == *'rev-parse HEAD' ]]; then [[ ${SCENARIO:-} == head_changed ]] && printf '%s\n' 2222222222222222222222222222222222222222 || printf '%s\n' "$FAKE_HEAD"; exit 0; fi
if [[ $* == *'rev-parse --verify '* ]]; then
  value=${@: -1}; printf '%s\n' "${value/\^\{commit\}/}"; exit 0
fi
if [[ $* == *'ls-tree -r --name-only '* ]]; then
  printf '%s\n' README.md ops/images/Dockerfile.moss ops/images/Dockerfile.moss-all-in-one; exit 0
fi
if [[ $* == *'diff --cached --binary' ]]; then
  [[ ${SCENARIO:-} == staged_changed ]] && printf '%s\n' staged-diff-changed || printf '%s\n' baseline-staged-diff; exit 0
fi
if [[ $* == *'archive --format=tar '* ]]; then
  /usr/bin/tar -cf - -C "$TEST_TMP/archive" README.md ops; exit 0
fi
exit 1
EOF
  cat >"$tmp/fakebin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker %s\n' "$*" >>"$CALL_LOG"
args="$*"
if [[ $args == build* ]]; then
  count_file="$TEST_TMP/build-count"; count=$(cat "$count_file" 2>/dev/null || printf 0); count=$((count + 1)); printf '%s' "$count" >"$count_file"
  context=${@: -1}
  test -d "$context"
  test ! -e "$context/.candidate-dirty"
  test ! -e "$context/env/.candidate-ignored.env"
  [[ ${SCENARIO:-} == second_build_failure && $count -eq 2 ]] && exit 23
  exit 0
fi
if [[ $args == *'image inspect '* && $args == *'{{.Id}}'* ]]; then
  if [[ ${SCENARIO:-} == candidate_id_changed ]]; then
    printf '%s\n' sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
  else
    printf '%s\n' "$CANDIDATE_IMAGE_ID"
  fi
  exit 0
fi
if [[ $args == *'image rm -f '* ]]; then
  [[ ${SCENARIO:-} == base_cleanup_failure ]] && exit 1
  exit 0
fi
if [[ $args == *'compose '* && $args == *' config' ]]; then
  [[ ${SCENARIO:-} == compose_changed ]] && printf 'rendered-compose-changed\n' || printf 'rendered-compose-baseline\n'
  exit 0
fi
if [[ $args == *'{{.Id}}|{{.Image}}'* && $args == *'the-ai-crowd-moss-1' ]]; then
  case ${SCENARIO:-} in
    missing_target) exit 1 ;;
    wrong_target) printf 'wrong-target|%s\n' "$OLD_IMAGE" ;;
    live_changed) printf 'live-container-changed|%s\n' "$OLD_IMAGE" ;;
    live_image_changed) printf 'live-container-baseline|sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\n' ;;
    *) printf 'live-container-baseline|%s\n' "$OLD_IMAGE" ;;
  esac
  exit 0
fi
if [[ $args == *'{{.Image}}'* && $args != *'.State.Status'* && $args == *' moss' ]]; then
  [[ ${SCENARIO:-} == pre_stop_failure ]] && exit 1
  printf '%s\n' "$OLD_IMAGE"; exit 0
fi
if [[ $args == *'.State.Status'* && $args == *'the-ai-crowd-moss-1' ]]; then
  count_file="$TEST_TMP/state-inspect-count"; count=$(cat "$count_file" 2>/dev/null || printf 0); count=$((count + 1)); printf '%s' "$count" >"$count_file"
  if [[ ${SCENARIO:-} == post_validate_failure && $count -eq 1 ]]; then printf 'running|unhealthy|%s\n' "$CANDIDATE_IMAGE_ID"; elif [[ ${SCENARIO:-} == post_stop_failure || ${SCENARIO:-} == post_validate_failure ]]; then printf 'running|healthy|%s\n' "$OLD_IMAGE"; else printf 'running|healthy|%s\n' "$CANDIDATE_IMAGE_ID"; fi
  exit 0
fi
if [[ $args == *'compose '* && $args == *' up -d --no-deps --force-recreate moss'* ]]; then
  count_file="$TEST_TMP/recreate-count"; count=$(cat "$count_file" 2>/dev/null || printf 0); count=$((count + 1)); printf '%s' "$count" >"$count_file"
  [[ ${SCENARIO:-} == post_stop_failure && $count -eq 1 ]] && exit 1
fi
exit 0
EOF
  cat >"$tmp/fakebin/tar" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'tar %s\n' "$*" >>"$CALL_LOG"
exec /usr/bin/tar "$@"
EOF
  cat >"$tmp/fakebin/rm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'rm %s\n' "$*" >>"$CALL_LOG"
if [[ $* == *moss-write-safe-root-context.* ]]; then
  case "${SCENARIO:-}" in
    context_cleanup_failure) exit 1 ;;
  esac
fi
exec /usr/bin/rm "$@"
EOF
  chmod +x "$tmp/fakebin/git" "$tmp/fakebin/docker" "$tmp/fakebin/tar" "$tmp/fakebin/rm"
}

assert_no_recreate() { ! grep -q -- '--force-recreate moss' "$CALL_LOG"; }
assert_no_production_mutation() {
  if grep -Eq '^docker image tag [^[:space:]]+ the-ai-crowd/moss-all-in-one:local$' "$CALL_LOG"; then return 1; fi
  if grep -q -- ' stop moss' "$CALL_LOG"; then return 1; fi
  assert_no_recreate
}
assert_only_evidence_file_changed() {
  local changed=$1 snapshot_file name state_file
  for snapshot_file in "$evidence_snapshot"/*; do
    name=${snapshot_file##*/}; state_file="$state_dir/$name"
    if [[ $name == "$changed" ]]; then ! cmp -s "$snapshot_file" "$state_file"; else cmp -s "$snapshot_file" "$state_file"; fi
  done
}
assert_immutable_image_id() { [[ $1 =~ ^sha256:[[:xdigit:]]{64}$ ]]; }
assert_rollback_exact() {
  grep -Fq "image tag $old_image the-ai-crowd/moss-all-in-one:local" "$CALL_LOG"
  test "$(grep -c -- 'up -d --no-deps --force-recreate moss' "$CALL_LOG")" -eq 2
}
run() {
  CALL_LOG="$CALL_LOG" TEST_TMP="$tmp" SCENARIO="${SCENARIO:-}" EXPECTED_IMAGE="${EXPECTED_IMAGE:-}" FAKE_HEAD="${FAKE_HEAD:-$commit}" OLD_IMAGE="$old_image" CANDIDATE="$candidate" CANDIDATE_IMAGE_ID="$candidate_image_id" PATH="$tmp/fakebin:$PATH" TMPDIR="$tmp/buildtmp" MOSS_WRITE_SAFE_ROOT_STATE_ROOT="$tmp/state" "$runner" "$@"
}
run_with_env() {
  local override=$1
  shift
  env "$override" CALL_LOG="$CALL_LOG" TEST_TMP="$tmp" SCENARIO="${SCENARIO:-}" EXPECTED_IMAGE="${EXPECTED_IMAGE:-}" FAKE_HEAD="${FAKE_HEAD:-$commit}" OLD_IMAGE="$old_image" CANDIDATE="$candidate" CANDIDATE_IMAGE_ID="$candidate_image_id" PATH="$tmp/fakebin:$PATH" TMPDIR="$tmp/buildtmp" MOSS_WRITE_SAFE_ROOT_STATE_ROOT="$tmp/state" "$runner" "$@"
}

make_fakes
assert_immutable_image_id "$old_image"
assert_immutable_image_id "$candidate_image_id"
: >"$tmp/calls"
if run >"$tmp/noargs" 2>&1; then echo 'no-args unexpectedly succeeded' >&2; exit 1; fi
run --help >"$tmp/help"
grep -q 'Usage:' "$tmp/help"
test ! -e "$tmp/state"
test ! -s "$tmp/calls"

# The mutation target is literal: malformed, bare, noncanonical, and environment
# override attempts must fail before Docker or state creation.
for invalid_container in bare moss another-container; do
  : >"$tmp/calls"
  case $invalid_container in
    bare) command=(--commit "$commit" --phase preflight --execute --container) ;;
    *) command=(--commit "$commit" --phase preflight --container "$invalid_container" --execute) ;;
  esac
  if run "${command[@]}" >"$tmp/invalid-container-$invalid_container" 2>&1; then
    echo "invalid container $invalid_container unexpectedly succeeded" >&2; exit 1
  fi
  assert_no_production_mutation
  ! grep -q '^docker ' "$CALL_LOG"
done
for override in MOSS_CANONICAL_CONTAINER=the-ai-crowd-moss-1 MOSS_CANONICAL_CONTAINER=alternate MOSS_COMPOSE_SERVICE=moss MOSS_COMPOSE_SERVICE=alternate; do
  : >"$tmp/calls"; rm -rf "$tmp/state"
  if run_with_env "$override" --commit "$commit" --phase preflight --execute >"$tmp/override-${override%%=*}" 2>&1; then
    echo "environment override $override unexpectedly succeeded" >&2; exit 1
  fi
  grep -q 'environment overrides are not allowed' "$tmp/override-${override%%=*}"
  assert_no_production_mutation
  ! grep -q '^docker ' "$CALL_LOG"
done

for phase in preflight build validate promote; do
  : >"$tmp/calls"
  run --commit "$commit" --phase "$phase" >"$tmp/dry-$phase"
  test "$(cat "$tmp/dry-$phase")" = "dry-run $phase"
  test ! -e "$tmp/state"
  test ! -s "$tmp/calls"
done

# A mismatched HEAD fails before state or any Docker mutation/recreate.
: >"$tmp/calls"
if FAKE_HEAD=2222222222222222222222222222222222222222 run --commit "$commit" --phase promote --execute >"$tmp/cas" 2>&1; then echo 'CAS mismatch unexpectedly succeeded' >&2; exit 1; fi
grep -q 'commit CAS mismatch' "$tmp/cas"
test ! -e "$tmp/state"
assert_no_recreate
test ! -s "$tmp/calls" || ! grep -q '^docker ' "$tmp/calls"

# These source-only fixtures simulate dirty and ignored inputs. The fake Docker
# command rejects either if a candidate build context receives them.
printf 'dirty source fixture\n' >"$repo/.candidate-dirty"
mkdir -p "$repo/env"; printf 'ignored env fixture\n' >"$repo/env/.candidate-ignored.env"
chmod 000 "$repo/.candidate-dirty" "$repo/env/.candidate-ignored.env"
trap 'chmod 600 "$repo/.candidate-dirty" "$repo/env/.candidate-ignored.env" 2>/dev/null || true; rm -f "$repo/.candidate-dirty" "$repo/env/.candidate-ignored.env"; rm -rf "$tmp"' EXIT

# Execute read-only phases against fakes and retain CAS-bound evidence.
: >"$tmp/calls"
run --commit "$commit" --phase preflight --execute
run --commit "$commit" --phase build --execute
run --commit "$commit" --phase validate --execute
grep -Fxq "$commit" "$tmp/state/write-safe-root-$commit/commit"
grep -Fxq 'phase=validate' "$tmp/state/write-safe-root-$commit/validate"
assert_no_recreate

# Candidate builds use only a git archive context: dirty/ignored source and env
# fixtures must not reach either Docker build, compose is forbidden here, and
# the commit-bound base tag/context are cleaned on success and failure.
base="the-ai-crowd/moss:write-safe-root-base-$commit"
test "$(grep -c '^docker build ' "$CALL_LOG")" -eq 2
grep -F -- "docker build --tag $base -f " "$CALL_LOG" | grep -Fq 'ops/images/Dockerfile.moss '
grep -F -- "docker build --tag $candidate --build-arg MOSS_BASE_IMAGE=$base -f " "$CALL_LOG" | grep -Fq 'ops/images/Dockerfile.moss-all-in-one '
grep -Fq "docker image rm -f $base" "$CALL_LOG"
grep -Fq "archive --format=tar $commit" "$CALL_LOG"
grep -Fq "ls-tree -r --name-only $commit" "$CALL_LOG"
test "$(grep -c '^tar ' "$CALL_LOG")" -eq 2
grep -Fq 'compose -f ' "$CALL_LOG"
! grep -q 'compose.*\(stop\|up -d\)\|env/' "$CALL_LOG"
test -z "$(find "$tmp/buildtmp" -mindepth 1 -print -quit)"

: >"$tmp/calls"; rm -f "$tmp/build-count"
set +e
SCENARIO=second_build_failure run --commit "$commit" --phase build --execute >"$tmp/second-build" 2>&1
build_rc=$?
set -e
[[ $build_rc -eq 23 ]] || { echo "build failure code was not preserved: $build_rc" >&2; exit 1; }
grep -Fq "docker image rm -f $base" "$CALL_LOG"
test -z "$(find "$tmp/buildtmp" -mindepth 1 -print -quit)"
! grep -q 'compose\|env/' "$CALL_LOG"

# Cleanup failures after a successful build fail closed. Both cleanup actions
# must still be attempted, invalidate prior same-commit evidence, and leave
# validation/promotion unable to reach Docker mutation.
for cleanup_scenario in base_cleanup_failure context_cleanup_failure; do
  : >"$tmp/calls"; rm -f "$tmp/build-count"
  if SCENARIO="$cleanup_scenario" run --commit "$commit" --phase build --execute >"$tmp/$cleanup_scenario" 2>&1; then
    echo "$cleanup_scenario unexpectedly succeeded" >&2; exit 1
  fi
  grep -Fq "docker image rm -f $base" "$CALL_LOG"
  grep -Fq "rm -rf $tmp/buildtmp/moss-write-safe-root-context." "$CALL_LOG"
  ! test -e "$tmp/state/write-safe-root-$commit/build"
  ! test -e "$tmp/state/write-safe-root-$commit/candidate-image-id"
  ! test -e "$tmp/state/write-safe-root-$commit/validate"
  ! test -e "$tmp/state/write-safe-root-$commit/promote"
  grep -Fxq 'build_cleanup_failed' "$tmp/state/write-safe-root-$commit/status"
  ! grep -q 'compose\|env/' "$CALL_LOG"

  : >"$tmp/calls"
  if run --commit "$commit" --phase validate --execute >"$tmp/$cleanup_scenario-validate" 2>&1; then
    echo "$cleanup_scenario validate unexpectedly succeeded" >&2; exit 1
  fi
  grep -q 'missing CAS-bound build evidence' "$tmp/$cleanup_scenario-validate"
  assert_no_recreate
  ! grep -q '^docker ' "$CALL_LOG"

  : >"$tmp/calls"
  if run --commit "$commit" --phase promote --execute >"$tmp/$cleanup_scenario-promote" 2>&1; then
    echo "$cleanup_scenario promote unexpectedly succeeded" >&2; exit 1
  fi
  grep -q 'missing CAS-bound validate evidence' "$tmp/$cleanup_scenario-promote"
  assert_no_recreate
  ! grep -q '^docker ' "$CALL_LOG"
done

# Restore successful evidence for validation and promotion coverage below.
: >"$tmp/calls"; rm -f "$tmp/build-count"
run --commit "$commit" --phase build --execute
run --commit "$commit" --phase validate --execute

# A moved candidate tag must fail validation before any promotion mutation.
: >"$tmp/calls"
if SCENARIO=candidate_id_changed run --commit "$commit" --phase validate --execute >"$tmp/candidate-id-changed" 2>&1; then echo 'candidate ID mismatch unexpectedly succeeded' >&2; exit 1; fi
grep -q 'candidate image ID changed after build' "$tmp/candidate-id-changed"
assert_no_recreate
! grep -q -- ' stop moss' "$tmp/calls"

# A missing canonical target is detected by the pre-mutation CAS check.
: >"$tmp/calls"
if SCENARIO=missing_target run --commit "$commit" --phase promote --execute >"$tmp/pre-stop" 2>&1; then echo 'missing target unexpectedly succeeded' >&2; exit 1; fi
grep -q 'canonical container target' "$tmp/pre-stop"
assert_no_recreate
! grep -q -- ' stop moss' "$tmp/calls"

# A recreate failure after stop must reapply the exact recorded image.
: >"$tmp/calls"; rm -f "$tmp/recreate-count" "$tmp/state-inspect-count"
if SCENARIO=post_stop_failure EXPECTED_IMAGE="$old_image" run --commit "$commit" --phase promote --execute >"$tmp/post-stop" 2>&1; then echo 'post-stop failure unexpectedly succeeded' >&2; exit 1; fi
grep -q -- ' stop moss' "$tmp/calls"
assert_rollback_exact
# The call log above proves rollback used the captured exact image.

# A post-recreate validation failure uses the same exact-image rollback path.
: >"$tmp/calls"; rm -f "$tmp/recreate-count" "$tmp/state-inspect-count"
if SCENARIO=post_validate_failure EXPECTED_IMAGE="$old_image" run --commit "$commit" --phase promote --execute >"$tmp/post-validate" 2>&1; then echo 'post-validate failure unexpectedly succeeded' >&2; exit 1; fi
assert_rollback_exact

# Successful promote validates the candidate and removes only temporary rollback state.
: >"$tmp/calls"; rm -f "$tmp/recreate-count" "$tmp/state-inspect-count"
EXPECTED_IMAGE="$candidate_image_id" run --commit "$commit" --phase promote --execute
! test -e "$tmp/state/write-safe-root-$commit/rollback-image"
grep -Fxq "$candidate_image_id" "$tmp/state/write-safe-root-$commit/candidate-image-id"
grep -Fxq 'phase=promote' "$tmp/state/write-safe-root-$commit/promote"
grep -Fxq "promote_complete" "$tmp/state/write-safe-root-$commit/status"
test "$(grep -c -- 'up -d --no-deps --force-recreate moss' "$tmp/calls")" -eq 1

# Activation preflight must bind the canonical target and every observed CAS value;
# changing any observed source/live/compose value must fail before Docker lifecycle.
: >"$tmp/calls"
run --commit "$commit" --phase preflight --execute
for evidence in activation-head activation-staged-diff-sha256 activation-container activation-container-id activation-live-image-id activation-compose-sha256 activation-candidate-image-id; do
  test -s "$tmp/state/write-safe-root-$commit/$evidence"
done
[[ $(<"$tmp/state/write-safe-root-$commit/activation-container") == the-ai-crowd-moss-1 ]]
grep -Fq 'the-ai-crowd-moss-1' "$CALL_LOG"

for mismatch in head_changed staged_changed live_changed compose_changed missing_target wrong_target candidate_id_changed live_image_changed; do
  : >"$tmp/calls"
  if SCENARIO="$mismatch" run --commit "$commit" --phase promote --execute >"$tmp/activation-$mismatch" 2>&1; then
    echo "activation $mismatch unexpectedly succeeded" >&2; exit 1
  fi
  grep -q 'activation CAS mismatch\|canonical container target' "$tmp/activation-$mismatch"
  assert_no_production_mutation
done

# Every persisted pre-mutation expectation is itself CAS data. A valid-looking
# but wrong file must prevent production tagging and lifecycle mutation.
evidence_snapshot="$tmp/activation-evidence-baseline"
state_dir="$tmp/state/write-safe-root-$commit"
cp -a "$state_dir" "$evidence_snapshot"

# This proof rejects the old source-specific tag assertion: a drifted image ID
# is still forbidden from becoming the production tag.
mutation_proof_log="$tmp/source-agnostic-tag-proof"
printf 'docker image tag sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc the-ai-crowd/moss-all-in-one:local\n' >"$mutation_proof_log"
saved_call_log=$CALL_LOG
CALL_LOG=$mutation_proof_log
if assert_no_production_mutation; then
  echo 'source-agnostic production-tag assertion unexpectedly passed' >&2; exit 1
fi
CALL_LOG=$saved_call_log

for evidence in activation-head activation-staged-diff-sha256 activation-container activation-container-id activation-live-image-id activation-compose-sha256 activation-candidate-image-id candidate-image-id; do
  # Start every case from the complete baseline. The comparison below proves
  # exactly one persisted-CAS file changed, so cumulative corruption cannot
  # make a later fixture pass on an earlier mismatch.
  rm -rf "$state_dir"
  cp -a "$evidence_snapshot" "$state_dir"
  case $evidence in
    activation-container) printf '%s\n' another-container >"$state_dir/$evidence" ;;
    activation-container-id) printf '%s\n' another-container-id >"$state_dir/$evidence" ;;
    *) printf '%s\n' sha256:ddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd >"$state_dir/$evidence" ;;
  esac
  assert_only_evidence_file_changed "$evidence"
  : >"$tmp/calls"
  if run --commit "$commit" --phase promote --execute >"$tmp/corrupt-$evidence" 2>&1; then
    echo "corrupt $evidence unexpectedly succeeded" >&2; exit 1
  fi
  assert_no_production_mutation
done
rm -rf "$state_dir"
cp -a "$evidence_snapshot" "$state_dir"
# The candidate image must remain available after validation for later review/activation.
test -s "$tmp/state/write-safe-root-$commit/candidate-image-id"
! grep -Fq "image rm -f $candidate" "$CALL_LOG"

echo runner_contract_ok
