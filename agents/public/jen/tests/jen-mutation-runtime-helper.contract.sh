#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/bin/jen-mutation-runtime-helper"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export JEN_IDEMPOTENCY_DIR="$TMP/idempotency"

base="$TMP/base.json"
with_ts="$TMP/with-ts.json"
changed="$TMP/changed.json"
with_provider="$TMP/with-provider.json"
blocked="$TMP/blocked.json"
high="$TMP/high.json"

cat > "$base" <<'JSON'
{
  "user_request_ref": "test:task",
  "operation_type": "create",
  "target_system": "todoist",
  "canonical_object_type": "task",
  "mutation_payload": {"content": "Comprar ração", "due_string": "tomorrow"}
}
JSON

cat > "$with_ts" <<'JSON'
{
  "user_request_ref": "test:task",
  "operation_type": "create",
  "target_system": "todoist",
  "canonical_object_type": "task",
  "mutation_payload": {"content": "Comprar ração", "due_string": "tomorrow"},
  "planned_at": "2026-04-25T20:00:00Z",
  "status": "verified",
  "verification_result": {"status": "passed"}
}
JSON

cat > "$changed" <<'JSON'
{
  "user_request_ref": "test:task",
  "operation_type": "create",
  "target_system": "todoist",
  "canonical_object_type": "task",
  "mutation_payload": {"content": "Comprar ração premium", "due_string": "tomorrow"}
}
JSON

cat > "$with_provider" <<'JSON'
{
  "user_request_ref": "test:task",
  "operation_type": "create",
  "target_system": "todoist",
  "canonical_object_type": "task",
  "mutation_payload": {"content": "Comprar ração", "due_string": "tomorrow"},
  "provider_result": {"id": "abc", "created_at": "later"},
  "result": {"provider": "ignored"}
}
JSON

h1=$($HELPER hash "$base" | jq -r '.normalized_hash')
h2=$($HELPER hash "$with_ts" | jq -r '.normalized_hash')
h3=$($HELPER hash "$changed" | jq -r '.normalized_hash')
h4=$($HELPER hash "$with_provider" | jq -r '.normalized_hash')
[[ "$h1" == "$h2" ]]
[[ "$h1" == "$h4" ]]
[[ "$h1" != "$h3" ]]

first=$($HELPER prepare "$base")
jq -e '.status == "ok" and .decision == "execute" and .idempotency.check_status == "miss" and (.gateway_plan.normalized_hash | startswith("nh_"))' <<<"$first" >/dev/null

second=$($HELPER prepare "$base")
jq -e '.decision == "unsafe_replay_state" and .idempotency.check_status == "duplicate" and .idempotency.record.status == "planned"' <<<"$second" >/dev/null

plan="$TMP/verified-plan.json"
jq '.gateway_plan + {result: {runtime_schema:"jen-task-runtime.v1", verified:true, task:{id:"task-1"}}}' <<<"$first" > "$plan"
$HELPER record --status verified "$plan" >/dev/null
verified=$($HELPER prepare "$base")
jq -e '.decision == "duplicate_verified" and .idempotency.record.result.verified == true' <<<"$verified" >/dev/null

failed_dir="$TMP/failed-idem"
export JEN_IDEMPOTENCY_DIR="$failed_dir"
failed_first=$($HELPER prepare "$base")
failed_plan="$TMP/failed-plan.json"
jq '.gateway_plan + {result: {partial:{external_object_id:"task-partial", failed_step:"update-due"}}}' <<<"$failed_first" > "$failed_plan"
$HELPER record --status failed "$failed_plan" >/dev/null
retry=$($HELPER prepare "$base")
jq -e '.decision == "retry_partial" and .idempotency.record.result.partial.external_object_id == "task-partial"' <<<"$retry" >/dev/null

export JEN_IDEMPOTENCY_DIR="$TMP/preflight-failed-idem"
preflight_first=$($HELPER prepare "$base")
preflight_plan="$TMP/preflight-plan.json"
jq '.gateway_plan + {result: {runtime_schema:"jen-task-runtime.v1", failed_step:"duplicate-preflight", failure_class:"unable_to_verify_duplicates", preflight:{status:"unable_to_verify_duplicates", reason:"active_read_failed"}}}' <<<"$preflight_first" > "$preflight_plan"
$HELPER record --status failed "$preflight_plan" >/dev/null
preflight_retry=$($HELPER prepare "$base")
jq -e '.decision == "execute" and .idempotency.check_status == "duplicate" and .idempotency.record.result.failed_step == "duplicate-preflight"' <<<"$preflight_retry" >/dev/null

export JEN_IDEMPOTENCY_DIR="$TMP/collision-idem"
collision_first=$($HELPER prepare "$base")
idem_key=$(jq -r '.gateway_plan.idempotency_key' <<<"$collision_first")
normalized=$(jq -r '.gateway_plan.normalized_hash' <<<"$collision_first")
"$ROOT/bin/jen-idempotency-store" put --kind intent --key "$idem_key" --normalized-hash "${normalized}-different" --ttl 14d --status planned >/dev/null
collision=$($HELPER prepare "$base")
jq -e '.decision == "collision" and .idempotency.record.status == "collision"' <<<"$collision" >/dev/null

export JEN_IDEMPOTENCY_DIR="$TMP/safe-recurring-idem"
recurring_first="$TMP/recurring-first.json"
recurring_next="$TMP/recurring-next.json"
cat > "$recurring_first" <<'JSON'
{
  "user_request_ref": "jen-task-runtime:update-due:robot:todo 2 semanas",
  "operation_type": "update",
  "target_system": "todoist",
  "canonical_object_type": "recurring_task",
  "external_object_id": "robot",
  "pre_state": {"id":"robot", "deadline": null, "due":{"date":"2026-05-10", "string":"todo 2 semanas", "lang":"pt", "is_recurring":true}},
  "mutation_payload": {"due_string":"todo 2 semanas", "recurring":true},
  "requires_confirmation": false
}
JSON
cat > "$recurring_next" <<'JSON'
{
  "user_request_ref": "jen-task-runtime:update-due:robot:todo 2 semanas",
  "operation_type": "update",
  "target_system": "todoist",
  "canonical_object_type": "recurring_task",
  "external_object_id": "robot",
  "pre_state": {"id":"robot", "deadline": null, "due":{"date":"2026-05-11", "string":"todo 2 semanas", "lang":"pt", "is_recurring":true}},
  "mutation_payload": {"due_string":"todo 2 semanas", "recurring":true},
  "requires_confirmation": false
}
JSON
safe_first=$($HELPER prepare "$recurring_first")
safe_plan="$TMP/safe-recurring-verified.json"
jq '.gateway_plan + {result: {runtime_schema:"jen-task-runtime.v1", verified:true, output:{status:"ok", command:"update-due", due_string:"todo 2 semanas"}}}' <<<"$safe_first" > "$safe_plan"
$HELPER record --status verified "$safe_plan" >/dev/null
safe_duplicate=$($HELPER prepare "$recurring_first")
jq -e '.decision == "duplicate_verified" and .idempotency.check_status == "duplicate"' <<<"$safe_duplicate" >/dev/null
safe_next=$($HELPER prepare "$recurring_next")
jq -e '.decision == "execute" and .idempotency.check_status == "miss" and .gateway_plan.idempotency_key != ($old.gateway_plan.idempotency_key)' --argjson old "$safe_first" <<<"$safe_next" >/dev/null

cat > "$blocked" <<'JSON'
{
  "operation_type": "delete",
  "target_system": "todoist",
  "canonical_object_type": "recurring_task",
  "external_object_id": "task-recurring",
  "pre_state": {"id":"task-recurring", "recurring": true},
  "mutation_payload": {"scope":"ambiguous"}
}
JSON
export JEN_IDEMPOTENCY_DIR="$TMP/blocked-idem"
blocked_out=$($HELPER prepare "$blocked")
jq -e '.decision == "blocked" and .gateway_plan.status == "blocked"' <<<"$blocked_out" >/dev/null

cat > "$high" <<'JSON'
{
  "operation_type": "move",
  "target_system": "google_calendar",
  "canonical_object_type": "event",
  "external_object_id": "evt-1",
  "pre_state": {"id":"evt-1", "attendees":["a@example.com"]},
  "mutation_payload": {"from":"2026-04-25T15:00:00-03:00", "to":"2026-04-25T16:00:00-03:00", "attendees":["a@example.com"]}
}
JSON
export JEN_IDEMPOTENCY_DIR="$TMP/high-idem"
high_out=$($HELPER prepare "$high")
jq -e '.decision == "awaiting_confirmation" and .gateway_plan.status == "awaiting_confirmation"' <<<"$high_out" >/dev/null

echo 'mutation runtime helper tests passed'
