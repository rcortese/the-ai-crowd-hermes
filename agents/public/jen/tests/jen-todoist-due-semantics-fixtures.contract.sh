#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$ROOT/fixtures/todoist-due-semantics-v2/historical-golden-fixtures.json"

fail() {
  echo "assertion failed: $*" >&2
  exit 1
}

[[ -f "$FIXTURE" ]] || fail "missing historical golden fixture file: fixtures/todoist-due-semantics-v2/historical-golden-fixtures.json"
jq empty "$FIXTURE" || fail "fixture JSON is invalid"

assert_jq() {
  local message="${@: -1}"
  local argc=$#
  local filter_index=$((argc - 1))
  local filter="${!filter_index}"
  local jq_args=()
  if (( argc > 2 )); then
    jq_args=("${@:1:argc-2}")
  fi
  if ! jq -e "${jq_args[@]}" "$filter" "$FIXTURE" >/dev/null; then
    echo "assertion failed: $message" >&2
    jq -C . "$FIXTURE" >&2 || true
    exit 1
  fi
}

assert_jq '.schema == "jen.todoist_due_semantics.v2.historical_golden_fixtures" and .version == 2' 'fixture schema/version'
assert_jq '(.fixtures | type) == "array" and (.fixtures | length) >= 18' 'fixture array has required breadth'
assert_jq 'all(.fixtures[]; (.id|type)=="string" and (.content|type)=="string" and (.expected.category|type)=="string" and (.expected.evidence|type)=="object" and (.expected.rationale|type)=="string" and (.expected.mutation_eligibility|type)=="object")' 'all fixtures expose category, evidence, rationale, mutation eligibility'
assert_jq 'all(.fixtures[]; .expected.category | IN("soft_surface", "recurring_maintenance", "hard_deadline", "recurring_hard_obligation", "ambiguous"))' 'all expected categories are valid'
assert_jq 'all(.fixtures[]; (.expected.evidence.explicit_deadline|type)=="boolean" and (.expected.evidence.recurring_due|type)=="boolean" and (.expected.evidence.strong_hard_cues|type)=="array" and (.expected.evidence.ambiguous_cues|type)=="array" and (.expected.evidence.decision_source|type)=="string")' 'all evidence objects include required classifier fields'
assert_jq 'all(.fixtures[]; (.expected.mutation_eligibility.writable_by_morning_hygiene|type)=="boolean" and (.expected.mutation_eligibility.phase|type)=="string" and (.expected.mutation_eligibility.skip_reason == null or (.expected.mutation_eligibility.skip_reason|type)=="string"))' 'all mutation eligibility objects include writable flag, phase, skip reason'

# Incident-critical examples.
assert_jq '.fixtures[] | select(.id == "historical-grow-tomar-conta") | select(.content == "The-ai-crowd tomar conta do grow" and .expected.category == "soft_surface" and .expected.evidence.explicit_deadline == false and (.expected.evidence.ambiguous_cues | index("conta")) and (.expected.evidence.ambiguous_cues | index("tomar conta")) and .expected.mutation_eligibility.writable_by_morning_hygiene == true)' 'grow/tomar conta remains soft and writable only as soft surface'
assert_jq '.fixtures[] | select(.id == "historical-luz-enel") | select(.content == "Luz - Enel" and .deadline.date == "2026-06-05" and .expected.category == "hard_deadline" and .expected.evidence.explicit_deadline == true and .expected.evidence.decision_source == "explicit_deadline" and .expected.mutation_eligibility.writable_by_morning_hygiene == false and .expected.mutation_eligibility.skip_reason == "deadline_present")' 'Luz-Enel remains hard because of explicit deadline and is not writable'

# Required coverage groups from approved plan/spec.
for group in confirmed_soft_surface nonrecurring_soft_backlog recurring_maintenance confirmed_hard strong_hard_cue ambiguous_cue; do
  assert_jq --arg group "$group" 'any(.fixtures[]; (.coverage_groups // []) | index($group))' "missing coverage group $group"
done

assert_jq '[.fixtures[] | select((.coverage_groups // []) | index("recurring_maintenance"))] | length >= 4' 'recurring maintenance examples present'
assert_jq 'all(.fixtures[] | select((.coverage_groups // []) | index("recurring_maintenance")); .due.is_recurring == true and .expected.category == "recurring_maintenance" and .expected.evidence.recurring_due == true and .expected.mutation_eligibility.phase == "recurring_maintenance")' 'recurring fixtures preserve recurrence metadata'
assert_jq '[.fixtures[] | select((.coverage_groups // []) | index("nonrecurring_soft_backlog"))] | length >= 7' 'nonrecurring backlog examples present'
assert_jq 'all(.fixtures[] | select((.coverage_groups // []) | index("strong_hard_cue")); .expected.category == "hard_deadline" and (.expected.evidence.strong_hard_cues | length) > 0 and .expected.mutation_eligibility.writable_by_morning_hygiene == false)' 'strong hard cue fixtures are hard and not soft-writable'
assert_jq 'all(.fixtures[] | select((.coverage_groups // []) | index("ambiguous_cue")); .expected.category != "hard_deadline" and .expected.category != "recurring_hard_obligation")' 'ambiguous cue fixtures are not hard solely from weak tokens'

# Policy/test consumers should be able to derive compact task input from fixtures without exposing unrelated user data.
jq -c '[.fixtures[] | {id, content, description:(.description // ""), labels:(.labels // []), due, deadline}]' "$FIXTURE" >/dev/null

echo "jen-todoist-due-semantics-fixtures-contract: ok"
