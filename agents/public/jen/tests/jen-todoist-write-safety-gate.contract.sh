#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin/jen-todoist-write-safety-gate"
FAKE_SECRET="FAKE_TODOIST_TOKEN_SHOULD_BE_REDACTED"

run_gate() {
  local payload="$1"
  printf '%s' "$payload" | "$BIN" --stdin
}

assert_common() {
  local json="$1"
  jq -e '.contract_version == "jen-todoist-write-safety-gate.v1"' <<<"$json" >/dev/null
  jq -e '.external_writes_performed == false and .write_scope == "mocked_write_safety_decision"' <<<"$json" >/dev/null
}

assert_nonempty_output() {
  local output="$1"
  local message="$2"
  [[ -n "$output" ]] || {
    echo "assertion failed: $message" >&2
    exit 1
  }
}

assert_no_secret() {
  local output="$1"
  local message="$2"
  if grep -Fq "$FAKE_SECRET" <<<"$output"; then
    echo "assertion failed: $message" >&2
    echo "$output" >&2
    exit 1
  fi
}

pre=$(run_gate '{"intent":{"labels":["task_capture"]}}')
assert_nonempty_output "$pre" 'pre-write decision should not be silent'
assert_common "$pre"
jq -e '.status == "needs_confirmation" and .copy_state == "real_chat_pre_write"' <<<"$pre" >/dev/null
jq -e '.forbidden_phrases | index("registrei")' <<<"$pre" >/dev/null
assert_no_secret "$pre" 'pre-write decision should not leak secrets'

failed_payload="$(jq -nc --arg secret "$FAKE_SECRET" '{intent:{labels:["task_capture"]},todoist_write:{status:"failed",error:$secret}}')"
failed=$(run_gate "$failed_payload")
assert_nonempty_output "$failed" 'failed decision should not be silent'
assert_common "$failed"
jq -e '.status == "failed" and .copy_state == "write_failed"' <<<"$failed" >/dev/null
jq -e '.forbidden_phrases | index("registrei")' <<<"$failed" >/dev/null
assert_no_secret "$failed" 'failed decision should redact error details'

unverified=$(run_gate '{"intent":{"labels":["task_capture"]},"todoist_write":{"status":"created","id":"abc","content":"almoçar"}}')
assert_nonempty_output "$unverified" 'unverified decision should not be silent'
assert_common "$unverified"
jq -e '.status == "blocked" and .copy_state == "write_unverified" and .reason == "missing_read_after_write"' <<<"$unverified" >/dev/null
jq -e '.forbidden_phrases | index("registrei")' <<<"$unverified" >/dev/null

not_found=$(run_gate '{"intent":{"labels":["task_capture"]},"todoist_write":{"status":"created","id":"abc"},"read_after_write":{"found":false}}')
assert_nonempty_output "$not_found" 'not-found decision should not be silent'
assert_common "$not_found"
jq -e '.status == "blocked" and .reason == "read_after_write_not_found"' <<<"$not_found" >/dev/null

mismatch=$(run_gate '{"intent":{"labels":["task_capture"]},"todoist_write":{"status":"created","id":"abc"},"read_after_write":{"found":true,"id":"other"}}')
assert_nonempty_output "$mismatch" 'mismatch decision should not be silent'
assert_common "$mismatch"
jq -e '.status == "blocked" and .reason == "read_after_write_id_mismatch"' <<<"$mismatch" >/dev/null

verified=$(run_gate '{"intent":{"labels":["task_capture"]},"todoist_write":{"status":"created","id":"abc","content":"almoçar"},"read_after_write":{"found":true,"id":"abc","content":"almoçar"}}')
assert_nonempty_output "$verified" 'verified decision should not be silent'
assert_common "$verified"
jq -e '.status == "verified" and .copy_state == "post_write_verified" and .requires == "verified_write_result"' <<<"$verified" >/dev/null
jq -e '(.allowed_phrases | index("registrei")) and (.forbidden_phrases | index("posso registrar?"))' <<<"$verified" >/dev/null
jq -e '.proof.write_id == "abc" and .proof.verified_id == "abc"' <<<"$verified" >/dev/null

no_intent=$(run_gate '{"intent":{"labels":["answer_or_discuss"]},"todoist_write":{"status":"created","id":"abc"},"read_after_write":{"found":true,"id":"abc"}}')
assert_nonempty_output "$no_intent" 'no-intent decision should not be silent'
assert_common "$no_intent"
jq -e '.status == "blocked" and .reason == "no_task_capture_intent"' <<<"$no_intent" >/dev/null
jq -e '.copy_state != "post_write_verified"' <<<"$no_intent" >/dev/null

set +e
probe_json="$($BIN --probe --dry-run)"
probe_status=$?
set -e
[[ "$probe_status" == "0" ]] || { echo 'assertion failed: probe dry-run should exit 0' >&2; printf '%s\n' "$probe_json" >&2; exit 1; }
assert_nonempty_output "$probe_json" 'probe dry-run should not be silent'
assert_common "$probe_json"
jq -e '.status == "ok" and .mode == "probe" and .dry_run == true and .reason == "probe_ready"' <<<"$probe_json" >/dev/null
assert_no_secret "$probe_json" 'probe dry-run should not leak secrets'

set +e
probe_live="$($BIN --probe 2>&1)"
probe_live_status=$?
set -e
[[ "$probe_live_status" == "1" ]] || { echo 'assertion failed: probe without dry-run should fail closed' >&2; printf '%s\n' "$probe_live" >&2; exit 1; }
assert_nonempty_output "$probe_live" 'probe without dry-run should not be silent'
printf '%s' "$probe_live" | grep -qi 'dry-run' || { echo 'assertion failed: probe without dry-run should mention dry-run' >&2; exit 1; }

set +e
probe_bad_json="$($BIN --probe --dry-run '{"status":"failed","reason":"fixture_invalid"}')"
probe_bad_status=$?
set -e
[[ "$probe_bad_status" == "1" ]] || { echo 'assertion failed: unhealthy probe fixture should fail' >&2; printf '%s\n' "$probe_bad_json" >&2; exit 1; }
assert_nonempty_output "$probe_bad_json" 'probe unhealthy fixture should not be silent'
assert_common "$probe_bad_json"
jq -e '.status == "failed" and .mode == "probe" and .dry_run == true and .reason == "fixture_invalid"' <<<"$probe_bad_json" >/dev/null

echo 'todoist write safety gate tests passed'
