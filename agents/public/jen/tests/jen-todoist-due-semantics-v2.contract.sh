#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$ROOT/fixtures/todoist-due-semantics-v2/historical-golden-fixtures.json"
POLICY="$ROOT/config/todoist-due-semantics-policy.v2.json"
CLASSIFIER="$ROOT/bin/jen-todoist-due-semantics"
fail(){ echo "assertion failed: $*" >&2; exit 1; }
[[ -f "$POLICY" ]] || fail "missing v2 policy file"
jq -e '.version == 2 and (.caps.soft_non_recurring_max_candidates == 25) and (.ambiguous_patterns|length) >= 3 and (.strong_hard_cues|index("boleto"))' "$POLICY" >/dev/null || fail "policy schema/defaults"
input="$(jq -c '[.fixtures[] | {id, content, description:(.description // ""), labels:(.labels // []), due, deadline}]' "$FIXTURE")"
out="$(JEN_TODOIST_DUE_SEMANTICS_POLICY="$POLICY" "$CLASSIFIER" classify --today 2026-06-01 <<<"$input")"
jq -e '.contract_version == "jen-todoist-due-semantics.v2" and .status == "ok" and .policy.version == 2 and .policy.sha256 and (.tasks|length) >= 18' <<<"$out" >/dev/null || fail "v2 envelope/policy evidence"
jq -e 'all(.tasks[]; (.evidence.explicit_deadline|type)=="boolean" and (.evidence.recurring_due|type)=="boolean" and (.evidence.strong_hard_cues|type)=="array" and (.evidence.ambiguous_cues|type)=="array" and (.evidence.soft_policy_matches|type)=="array" and (.evidence.hard_policy_matches|type)=="array" and (.evidence.ambiguous_policy_matches|type)=="array" and (.evidence|has("task_override")) and (.decision_source|type)=="string" and (.final_category|type)=="string" and (.writable|type)=="boolean")' <<<"$out" >/dev/null || fail "required evidence schema"
jq -e '.tasks[] | select(.id == "historical-grow-tomar-conta") | select(.final_category == "soft_surface" and .decision_source == "due_no_hard_evidence" and .writable == true and (.evidence.ambiguous_cues|index("conta")) and (.evidence.ambiguous_cues|index("tomar conta")) and (.evidence.strong_hard_cues|length == 0))' <<<"$out" >/dev/null || fail "grow/tomar conta must be soft with ambiguous evidence"
jq -e '.tasks[] | select(.id == "historical-luz-enel") | select(.final_category == "hard_deadline" and .decision_source == "explicit_deadline" and .writable == false and .skip_reason == "deadline_present" and .evidence.explicit_deadline == true)' <<<"$out" >/dev/null || fail "Luz-Enel hard due explicit deadline"
jq -e 'all(.tasks[] | select(.id|startswith("ambiguous-")); .final_category != "hard_deadline" and .final_category != "recurring_hard_obligation")' <<<"$out" >/dev/null || fail "ambiguous cues not hard alone"
jq -e '[.tasks[] | select(.final_category == "recurring_maintenance" and .due.is_recurring == true)] | length >= 4' <<<"$out" >/dev/null || fail "recurring maintenance coverage"
jq -e '[.tasks[] | select(.decision_source == "strong_hard_cue_combination" and .final_category == "hard_deadline" and .writable == false)] | length >= 4' <<<"$out" >/dev/null || fail "strong hard cue combinations"

# Fresh-review regression: reviewed policy patterns must match against the task text,
# not against the policy-entry object while iterating entries.
policy_smoke="$(mktemp)"
input_smoke="$(mktemp)"
trap 'rm -f "$policy_smoke" "$input_smoke"' EXIT
cat >"$policy_smoke" <<'JSON'
{"version":2,"task_overrides":{},"soft_patterns":[{"id":"soft-foo","pattern":"foo","match_mode":"token","category":"soft_surface","reason":"test","source":"contract"}],"hard_patterns":[{"id":"hard-reviewed-boleto","pattern":"reviewed boleto","match_mode":"phrase","category":"hard_deadline","reason":"test","source":"contract"}],"ambiguous_patterns":[{"id":"ambiguous-maybe","pattern":"maybe","match_mode":"token","category":"ambiguous","reason":"test","source":"contract"}],"strong_hard_cues":["pagar","boleto","pay","invoice"],"caps":{"soft_non_recurring_max_candidates":25,"recurring_max_candidates":25}}
JSON
cat >"$input_smoke" <<'JSON'
[
  {"id":"policy-soft","content":"foo bar","due":{"date":"2026-05-31","is_recurring":false},"deadline":null},
  {"id":"policy-hard","content":"reviewed boleto","due":{"date":"2026-05-31","is_recurring":false},"deadline":null},
  {"id":"policy-ambiguous","content":"maybe later","due":{"date":"2026-05-31","is_recurring":false},"deadline":null},
  {"id":"standalone-pagar","content":"pagar qualquer coisa","due":{"date":"2026-05-31","is_recurring":false},"deadline":null},
  {"id":"combo-pagar-boleto","content":"pagar boleto condomínio","due":{"date":"2026-05-31","is_recurring":false},"deadline":null},
  {"id":"combo-pay-invoice","content":"Pay invoice for hosting","due":{"date":"2026-05-31","is_recurring":false},"deadline":null},
  {"id":"recurring-standalone-pagar","content":"pagar qualquer coisa","due":{"date":"2026-05-31","string":"todo mês","is_recurring":true},"deadline":null},
  {"id":"recurring-combo-pagar-boleto","content":"pagar boleto condomínio","due":{"date":"2026-05-31","string":"todo mês","is_recurring":true},"deadline":null}
]
JSON
smoke_out="$(JEN_TODOIST_DUE_SEMANTICS_POLICY="$policy_smoke" "$CLASSIFIER" classify --today 2026-06-01 <"$input_smoke")"
jq -e '.tasks[] | select(.id == "policy-soft") | select(.final_category == "soft_surface" and .decision_source == "soft_policy_match" and (.evidence.soft_policy_matches|index("soft-foo")))' <<<"$smoke_out" >/dev/null || fail "soft policy pattern must match task text"
jq -e '.tasks[] | select(.id == "policy-hard") | select(.final_category == "hard_deadline" and .decision_source == "hard_policy_match" and (.evidence.hard_policy_matches|index("hard-reviewed-boleto")))' <<<"$smoke_out" >/dev/null || fail "hard policy pattern must match task text"
jq -e '.tasks[] | select(.id == "policy-ambiguous") | select(.final_category == "soft_surface" and .decision_source == "due_no_hard_evidence" and (.evidence.ambiguous_policy_matches|index("ambiguous-maybe")))' <<<"$smoke_out" >/dev/null || fail "ambiguous policy pattern evidence must match task text"
jq -e '.tasks[] | select(.id == "standalone-pagar") | select(.final_category == "ambiguous" and .decision_source == "strong_hard_cue_insufficient" and .writable == false and (.evidence.strong_hard_cues == ["pagar"]))' <<<"$smoke_out" >/dev/null || fail "standalone strong cue must fail closed, not hard"
jq -e '.tasks[] | select(.id == "recurring-standalone-pagar") | select(.final_category == "ambiguous" and .decision_source == "strong_hard_cue_insufficient" and .writable == false and .skip_reason == "strong_hard_cue_insufficient" and (.evidence.strong_hard_cues == ["pagar"]))' <<<"$smoke_out" >/dev/null || fail "recurring standalone strong cue must fail closed, not recurring maintenance writable"
jq -e '.tasks[] | select(.id == "combo-pagar-boleto") | select(.final_category == "hard_deadline" and .decision_source == "strong_hard_cue_combination" and (.evidence.strong_hard_cues|length) >= 2)' <<<"$smoke_out" >/dev/null || fail "strong hard cue combination still hard"
jq -e '.tasks[] | select(.id == "combo-pay-invoice") | select(.final_category == "hard_deadline" and .decision_source == "strong_hard_cue_combination" and (.evidence.strong_hard_cues|index("pay")) and (.evidence.strong_hard_cues|index("invoice")))' <<<"$smoke_out" >/dev/null || fail "English pay/invoice combination hard"
jq -e '.tasks[] | select(.id == "recurring-combo-pagar-boleto") | select(.final_category == "recurring_hard_obligation" and .decision_source == "strong_hard_cue_combination" and .writable == false and .skip_reason == "recurring_hard_obligation" and (.evidence.strong_hard_cues|index("pagar")) and (.evidence.strong_hard_cues|index("boleto")))' <<<"$smoke_out" >/dev/null || fail "recurring strong hard cue combination must not be recurring maintenance writable"

echo "jen-todoist-due-semantics-v2-contract: ok"
