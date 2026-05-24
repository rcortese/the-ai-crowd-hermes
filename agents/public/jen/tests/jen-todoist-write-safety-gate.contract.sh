#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin/jen-todoist-write-safety-gate"

run_gate() {
  jq -nc "$1" | "$BIN" --stdin
}

assert_common() {
  local json="$1"
  jq -e '.contract_version == "jen-todoist-write-safety-gate.v1"' <<<"$json" >/dev/null
  jq -e '.external_writes_performed == false and .write_scope == "mocked_write_safety_decision"' <<<"$json" >/dev/null
}

pre=$(run_gate '{intent:{labels:["task_capture"]}}')
assert_common "$pre"
jq -e '.status == "needs_confirmation" and .copy_state == "real_chat_pre_write"' <<<"$pre" >/dev/null
jq -e '.forbidden_phrases | index("registrei")' <<<"$pre" >/dev/null

failed=$(run_gate '{intent:{labels:["task_capture"]}, todoist_write:{status:"failed", error:"boom"}}')
assert_common "$failed"
jq -e '.status == "failed" and .copy_state == "write_failed"' <<<"$failed" >/dev/null
jq -e '.forbidden_phrases | index("registrei")' <<<"$failed" >/dev/null

unverified=$(run_gate '{intent:{labels:["task_capture"]}, todoist_write:{status:"created", id:"abc", content:"almoçar"}}')
assert_common "$unverified"
jq -e '.status == "blocked" and .copy_state == "write_unverified" and .reason == "missing_read_after_write"' <<<"$unverified" >/dev/null
jq -e '.forbidden_phrases | index("registrei")' <<<"$unverified" >/dev/null

not_found=$(run_gate '{intent:{labels:["task_capture"]}, todoist_write:{status:"created", id:"abc"}, read_after_write:{found:false}}')
assert_common "$not_found"
jq -e '.status == "blocked" and .reason == "read_after_write_not_found"' <<<"$not_found" >/dev/null

mismatch=$(run_gate '{intent:{labels:["task_capture"]}, todoist_write:{status:"created", id:"abc"}, read_after_write:{found:true, id:"other"}}')
assert_common "$mismatch"
jq -e '.status == "blocked" and .reason == "read_after_write_id_mismatch"' <<<"$mismatch" >/dev/null

verified=$(run_gate '{intent:{labels:["task_capture"]}, todoist_write:{status:"created", id:"abc", content:"almoçar"}, read_after_write:{found:true, id:"abc", content:"almoçar"}}')
assert_common "$verified"
jq -e '.status == "verified" and .copy_state == "post_write_verified" and .requires == "verified_write_result"' <<<"$verified" >/dev/null
jq -e '(.allowed_phrases | index("registrei")) and (.forbidden_phrases | index("posso registrar?"))' <<<"$verified" >/dev/null
jq -e '.proof.write_id == "abc" and .proof.verified_id == "abc"' <<<"$verified" >/dev/null

no_intent=$(run_gate '{intent:{labels:["answer_or_discuss"]}, todoist_write:{status:"created", id:"abc"}, read_after_write:{found:true, id:"abc"}}')
assert_common "$no_intent"
jq -e '.status == "blocked" and .reason == "no_task_capture_intent"' <<<"$no_intent" >/dev/null
jq -e '.copy_state != "post_write_verified"' <<<"$no_intent" >/dev/null

echo 'todoist write safety gate tests passed'
