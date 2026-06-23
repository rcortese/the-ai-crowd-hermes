#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin/jen-todoist-capture"
FIXTURE_DIR="$ROOT/tests/fixtures/canonical-capture"
FAKE_SECRET="FAKE_TODOIST_TOKEN_SHOULD_BE_REDACTED"

assert_jq() {
  local json="$1"
  local filter="$2"
  local message="$3"
  if ! jq -e "$filter" <<<"$json" >/dev/null; then
    echo "assertion failed: $message" >&2
    echo "$json" >&2
    exit 1
  fi
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local message="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "assertion failed: $message" >&2
    echo "expected: $expected" >&2
    echo "actual:   $actual" >&2
    exit 1
  fi
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

assert_single_json_object() {
  local json="$1"
  local message="$2"
  assert_nonempty_output "$json" "$message"
  assert_jq "$json" 'type == "object"' "$message"
}

assert_enum_member() {
  local value="$1"
  local message="$2"
  shift 2
  local allowed
  for allowed in "$@"; do
    if [[ "$value" == "$allowed" ]]; then
      return 0
    fi
  done
  echo "assertion failed: $message" >&2
  echo "unexpected value: $value" >&2
  exit 1
}

assert_envelope() {
  local json="$1"
  local message="$2"
  assert_single_json_object "$json" "$message"
  assert_enum_member "$(jq -r '.result // empty' <<<"$json")" "$message result enum" changed no_change partial failed
  assert_enum_member "$(jq -r '.failure_class // empty' <<<"$json")" "$message failure_class enum" none ambiguity policy_blocked technical_failure privacy_redaction
  assert_enum_member "$(jq -r '.jen_action // empty' <<<"$json")" "$message jen_action enum" acknowledge_changed acknowledge_no_change ask_user_clarification explain_policy_boundary stop_and_handoff_to_moss
  assert_jq "$json" '.operator_message | type == "string" and length > 0' "$message operator_message present"
  assert_no_secret "$json" "$message secret leakage"
}

assert_has_handoff() {
  local json="$1"
  local message="$2"
  local handoff_id
  handoff_id="$(jq -r '.handoff_id // empty' <<<"$json")"
  [[ -n "$handoff_id" ]] || {
    echo "assertion failed: $message" >&2
    echo "$json" >&2
    exit 1
  }
}

assert_no_handoff() {
  local json="$1"
  local message="$2"
  local handoff_id
  handoff_id="$(jq -r '.handoff_id // empty' <<<"$json")"
  [[ -z "$handoff_id" ]] || {
    echo "assertion failed: $message" >&2
    echo "$json" >&2
    exit 1
  }
}

for required in \
  "$FIXTURE_DIR/not-a-task.json" \
  "$FIXTURE_DIR/ambiguous.json" \
  "$FIXTURE_DIR/canonical-new.json" \
  "$FIXTURE_DIR/canonical-reconcile.json" \
  "$FIXTURE_DIR/technical-failure.json" \
  "$FIXTURE_DIR/redaction-debug.json"; do
  [[ -f "$required" ]] || { echo "assertion failed: missing fixture $required" >&2; exit 1; }
  jq empty "$required" >/dev/null
 done

not_a_task="$($BIN --json --dry-run --input "$FIXTURE_DIR/not-a-task.json")"
assert_envelope "$not_a_task" 'not-a-task envelope'
assert_jq "$not_a_task" '.result == "no_change" and .failure_class == "none" and .jen_action == "acknowledge_no_change"' 'not-a-task semantic contract'
assert_no_handoff "$not_a_task" 'not-a-task should not open handoff'

ambiguous="$($BIN --json --dry-run --input "$FIXTURE_DIR/ambiguous.json")"
assert_envelope "$ambiguous" 'ambiguous envelope'
assert_jq "$ambiguous" '.result == "no_change" and .failure_class == "ambiguity" and .jen_action == "ask_user_clarification"' 'ambiguous semantic contract'
assert_jq "$ambiguous" '.operator_message | test("nothing|written|yet|clarif"; "i")' 'ambiguous copy says nothing written yet'
assert_no_handoff "$ambiguous" 'ambiguity should not open handoff'

canonical_new="$($BIN --json --dry-run --input "$FIXTURE_DIR/canonical-new.json")"
assert_envelope "$canonical_new" 'canonical new envelope'
assert_jq "$canonical_new" '.result == "changed" and .failure_class == "none" and .jen_action == "acknowledge_changed"' 'canonical new semantic contract'
assert_no_handoff "$canonical_new" 'successful create should not open handoff'

canonical_reconcile="$($BIN --json --dry-run --input "$FIXTURE_DIR/canonical-reconcile.json")"
assert_envelope "$canonical_reconcile" 'canonical reconcile envelope'
assert_jq "$canonical_reconcile" '.result == "changed" and .failure_class == "none" and .jen_action == "acknowledge_changed"' 'canonical reconcile semantic contract'
assert_no_handoff "$canonical_reconcile" 'successful reconcile should not open handoff'

set +e
technical_failure="$($BIN --json --debug --dry-run --input "$FIXTURE_DIR/technical-failure.json" 2>&1)"
technical_failure_status=$?
set -e
assert_eq "$technical_failure_status" "1" 'technical failure exits nonzero'
assert_envelope "$technical_failure" 'technical failure envelope'
assert_jq "$technical_failure" '.result == "failed" and .failure_class == "technical_failure" and .jen_action == "stop_and_handoff_to_moss"' 'technical failure semantic contract'
assert_has_handoff "$technical_failure" 'technical failure should emit handoff id'

set +e
redaction_debug="$($BIN --json --verbose --debug --dry-run --input "$FIXTURE_DIR/redaction-debug.json" 2>&1)"
redaction_debug_status=$?
set -e
assert_eq "$redaction_debug_status" "1" 'redaction debug exits nonzero'
assert_envelope "$redaction_debug" 'redaction debug envelope'
assert_jq "$redaction_debug" '.result == "failed" and .failure_class == "technical_failure" and .jen_action == "stop_and_handoff_to_moss"' 'redaction debug semantic contract'
assert_has_handoff "$redaction_debug" 'redaction debug should emit handoff id'
assert_no_secret "$redaction_debug" 'redaction debug should not leak fake secret'

echo 'jen-todoist-capture failure-standard contract tests: ok'
