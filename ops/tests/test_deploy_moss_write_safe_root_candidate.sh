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
  mkdir -p "$tmp/fakebin"
  cat >"$tmp/fakebin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'git %s\n' "$*" >>"$CALL_LOG"
if [[ $* == *'rev-parse HEAD' ]]; then printf '%s\n' "$FAKE_HEAD"; exit 0; fi
if [[ $* == *'rev-parse --verify '* ]]; then
  value=${@: -1}; printf '%s\n' "${value/\^\{commit\}/}"; exit 0
fi
exit 1
EOF
  cat >"$tmp/fakebin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker %s\n' "$*" >>"$CALL_LOG"
args="$*"
if [[ $args == *'image inspect '* && $args == *'{{.Id}}'* ]]; then
  if [[ ${SCENARIO:-} == candidate_id_changed ]]; then
    printf '%s\n' sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
  else
    printf '%s\n' "$CANDIDATE_IMAGE_ID"
  fi
  exit 0
fi
if [[ $args == *'{{.Image}}'* && $args != *'.State.Status'* && $args == *' moss' ]]; then
  [[ ${SCENARIO:-} == pre_stop_failure ]] && exit 1
  printf '%s\n' "$OLD_IMAGE"; exit 0
fi
if [[ $args == *'.State.Status'* && $args == *' moss' ]]; then
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
  chmod +x "$tmp/fakebin/git" "$tmp/fakebin/docker"
}

assert_no_recreate() { ! grep -q -- '--force-recreate moss' "$CALL_LOG"; }
assert_immutable_image_id() { [[ $1 =~ ^sha256:[[:xdigit:]]{64}$ ]]; }
assert_rollback_exact() {
  grep -Fq "image tag $old_image the-ai-crowd/moss-all-in-one:local" "$CALL_LOG"
  test "$(grep -c -- 'up -d --no-deps --force-recreate moss' "$CALL_LOG")" -eq 2
}
run() {
  CALL_LOG="$CALL_LOG" TEST_TMP="$tmp" SCENARIO="${SCENARIO:-}" EXPECTED_IMAGE="${EXPECTED_IMAGE:-}" FAKE_HEAD="${FAKE_HEAD:-$commit}" OLD_IMAGE="$old_image" CANDIDATE="$candidate" CANDIDATE_IMAGE_ID="$candidate_image_id" PATH="$tmp/fakebin:$PATH" MOSS_WRITE_SAFE_ROOT_STATE_ROOT="$tmp/state" "$runner" "$@"
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

# Execute read-only phases against fakes and retain CAS-bound evidence.
: >"$tmp/calls"
run --commit "$commit" --phase preflight --execute
run --commit "$commit" --phase build --execute
run --commit "$commit" --phase validate --execute
grep -Fxq "$commit" "$tmp/state/write-safe-root-$commit/commit"
grep -Fxq 'phase=validate' "$tmp/state/write-safe-root-$commit/validate"
assert_no_recreate

# A moved candidate tag must fail validation before any promotion mutation.
: >"$tmp/calls"
if SCENARIO=candidate_id_changed run --commit "$commit" --phase validate --execute >"$tmp/candidate-id-changed" 2>&1; then echo 'candidate ID mismatch unexpectedly succeeded' >&2; exit 1; fi
grep -q 'candidate image ID changed after build' "$tmp/candidate-id-changed"
assert_no_recreate
! grep -q -- ' stop moss' "$tmp/calls"

# Capturing the old image is pre-mutation: its failure must not stop/recreate.
: >"$tmp/calls"
if SCENARIO=pre_stop_failure run --commit "$commit" --phase promote --execute >"$tmp/pre-stop" 2>&1; then echo 'pre-stop failure unexpectedly succeeded' >&2; exit 1; fi
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

echo runner_contract_ok
