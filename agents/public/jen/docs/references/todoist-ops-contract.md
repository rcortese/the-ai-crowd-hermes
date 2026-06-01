# Todoist Ops Contract

## Canonical integration path
- Use `bin/jen-task-runtime` as the only supported semantic runtime boundary for Jen Todoist operations.
- External Todoist mutations must be representable as `bin/jen-mutation-gateway plan` records before execution. The gateway owns risk classification, idempotency key derivation, confirmation posture, and audit references for mutation intent.
- `bin/jen-task-runtime` is the only supported semantic caller of `tools/todoist/todoist-api.sh`.
- `bin/jen-todoist-self-heal` is the narrow read-only support wrapper for Todoist failure classification, transient retry, sanitized Moss incident generation, and durable verification state. It must call Todoist only through `bin/jen-task-runtime`; it is not a write path.
- If this workspace declares `tools/todoist/todoist-api.sh`, that adapter is authoritative for Todoist capability checks and writes behind the runtime boundary.
- Chat-time Todoist mutations must not call `tools/todoist/todoist-api.sh` or generic Todoist mutation commands directly. They must use `bin/jen-task-runtime` or an approved thin wrapper that delegates to it.
- `bin/jen-todoist-capture` is the direct-chat capture wrapper and delegates to `bin/jen-task-runtime capture-task`.
- `bin/jen-morning-due-adjust` is the active morning due-date hygiene wrapper. It classifies past-due `due` signals through `bin/jen-todoist-due-semantics`, mutates only safe non-recurring `soft_surface` tasks with `deadline == null` through `bin/jen-task-runtime update-due`, preserves `deadline`, defaults to a max-candidate cap of 25, and writes a change log under `memory/morning-due-adjustments/` for later conversation.
- `tools/cron-scripts/jen-morning-soft-due-hygiene.sh` is the source-controlled copy of the single scheduled morning orchestration entrypoint installed at `/opt/data/scripts/jen-morning-soft-due-hygiene.sh`. It may synchronously call `/opt/data/scripts/jen-morning-recurring-maintenance-reanchor.sh`; do not add a second time-coupled cron for recurring maintenance.
- `tools/cron-scripts/jen-morning-recurring-maintenance-reanchor.sh` / runtime copy `/opt/data/scripts/jen-morning-recurring-maintenance-reanchor.sh` re-anchor only past-due `recurring_maintenance` tasks with `deadline == null`, `due.is_recurring == true`, and a non-empty `due.string`. It calls `jen-task-runtime update-due --due "$existing_due_string"`, defaults to max 25 candidates, fails closed before writes when the cap is exceeded, and records candidates/skipped/writes plus classifier evidence in `/opt/data/state/jen-cron/morning-recurring-maintenance-reanchor/latest.json` and audit packets.
- `bin/jen-todoist-due-semantics` v2 must report evidence separately from final decision. Lexical/regex matches populate evidence only; final category comes from deterministic precedence and reviewed policy.
- `config/todoist-due-semantics-policy.v2.json` is the auditable source for exact overrides and reviewed hard/soft/ambiguous patterns. Historical or Jen-context knowledge must be converted into this policy or into committed fixtures before it affects unattended write eligibility.
- `bin/jen-task-read` is the grouped direct-read wrapper and delegates to `bin/jen-task-runtime` read commands.
- `bin/jen-task-read recent-completed` is the supported grouped-read path for `read-recent-completed`; it delegates to the runtime and should not be treated as a separate wrapper category.
- Generic Todoist or task CLIs on `PATH` are observability only; their absence is not evidence that Todoist is unavailable, and their presence does not override the workspace adapter.
- Treat Todoist API v1 as canonical in this workspace.
- Do not assume REST v2 or Sync v9 are available.

## V2 due semantics validation workflow

Use this workflow when changing Todoist due semantics, policy, fixtures, morning due hygiene, or recurring maintenance re-anchor behavior. Run it in the Jen container without restarts, provider messages, calendar writes, or task creation.

1. Static source checks from `/agents/jen/public`:
   - `bash -n bin/jen-todoist-due-semantics bin/jen-morning-due-adjust tools/cron-scripts/jen-morning-soft-due-hygiene.sh tools/cron-scripts/jen-morning-recurring-maintenance-reanchor.sh tests/jen-todoist-due-semantics-v2.contract.sh tests/jen-morning-due-adjust.contract.sh tests/jen-morning-soft-due-hygiene-wrapper.contract.sh tests/jen-morning-recurring-maintenance-reanchor.contract.sh`
   - `jq -e . config/todoist-due-semantics-policy.v2.json fixtures/todoist-due-semantics-v2/historical-golden-fixtures.json`
2. Contract tests:
   - `tests/jen-todoist-due-semantics-v2.contract.sh`
   - `tests/jen-morning-due-adjust.contract.sh`
   - `tests/jen-morning-soft-due-hygiene-wrapper.contract.sh`
   - `tests/jen-morning-recurring-maintenance-reanchor.contract.sh`
3. Read-only live classifier smoke over a bounded window with `bin/jen-todoist-due-semantics live-due-window --from YYYY-MM-DD --to YYYY-MM-DD --today YYYY-MM-DD`. Confirm `The-ai-crowd tomar conta do grow` stays `soft_surface` and `Luz - Enel` stays `hard_deadline` because of explicit `deadline`.
4. Morning hygiene dry-run with `bin/jen-morning-due-adjust --dry-run ...`. Confirm candidate/write counts and cap state before any apply path.
5. Apply validation, only when candidates are zero or explicitly reviewed safe, through `/opt/data/scripts/jen-morning-soft-due-hygiene.sh` with `JEN_MORNING_SOFT_DUE_HYGIENE_APPLY=1`. Prefer this scheduled wrapper path because it writes audit/idempotency state under `/opt/data/state/jen-cron/...`; a bare source wrapper defaults to a read-only source-tree audit directory in the runtime container.
6. Read back `/opt/data/state/jen-cron/morning-soft-due-hygiene/latest.json`, `/opt/data/state/jen-cron/morning-recurring-maintenance-reanchor/latest.json`, and `/opt/data/cron/jobs.json`. Confirm both soft and recurring caps default to 25, fail closed on cap exceedance, preserve recurring `due.string`, skip deadline-bearing tasks, and keep exactly one scheduled cron named `Jen morning soft-due hygiene apply`.

No-touch confirmations for this workflow: no calendar writes, no Todoist task creation, no provider messages, no container/gateway restarts or recreates, no second time-based cron, and no direct LLM authorization of unattended Todoist writes.

## Runtime contract
- Contract version is pinned to `jen-task-runtime.v1`.
- All handled command outcomes emit exactly one JSON object on stdout.
- All `*_at` timestamp fields use RFC3339 UTC, for example `2026-04-24T16:03:00Z`.
- Diagnostics go to stderr only.
- Handled semantic failures emit a contract-valid JSON object on stdout with `status:"failed"` and a pinned `failure_class`, then exit non-zero.
- Chat delivery must translate handled runtime failures into visible, source-honest copy; a failed or degraded runtime result is not allowed to end as silence.
- No-JSON stdout is reserved only for exceptional launcher/internal breakage outside the handled command contract.
- `health` is a reporting command, not a failing probe surface: handled `health` outcomes always exit 0 and do not emit `failure_class`.

### Commands
- `health`
- `read-active`
- `capture-task --content <text> [--due <due_string>]`
- `update-due --task-id <task_id> --due <due_string>`
- `update-deadline --task-id <task_id> --deadline <YYYY-MM-DD>`
- `clear-deadline --task-id <task_id>`
- `move-task --task-id <task_id> (--project-id|--list-id) <project_id>`
- `read-recent-completed [--tasks --since <RFC3339> [--until <RFC3339>]]`
- `read-recent-activity --since <RFC3339> [--until <RFC3339>] [--limit N]`
- `read-activity-log --since <RFC3339> [--until <RFC3339>] [--limit N]`
- `read-recent-diff --since <RFC3339> [--until <RFC3339>] [--limit N] [--ttl-hours N]`
- `ensure-observation-baseline [--limit N] [--ttl-hours N] [--force]`
- `read-due-window --from <YYYY-MM-DD> --to <YYYY-MM-DD>`
- `explain-degraded-state`
- `classify-interaction-signals`

### Support/self-healing wrapper
- `bin/jen-todoist-self-heal health|read-active|read-recent-completed` probes only the canonical `bin/jen-task-runtime` path.
- It classifies unresolved failures as `transient`, `runtime/config`, or `credential/auth`; retries only transient failures; emits sanitized Moss incident JSON when unresolved; and writes durable verification state only after canonical health/read success.
- Fixed-state vocabulary is pinned to: `runtime restaurado; verificação pendente`, `health Todoist ok via caminho canônico; escrita não testada`, and `captura/leitura verificada no Todoist; pode chamar de corrigido`.
- Full support contract: `docs/references/todoist-self-healing-contract.md`.

### Pinned enums
- `health.status`: `ok | degraded | unavailable`
- `health.posture`: `available | degraded | unavailable`
- `health.authority`: `workspace-todoist-adapter`
- `health.token_status`: `set | missing`
- `read-active.status`: `ok | degraded | failed`
- `read-active.source`: `live | degraded-metadata`
- `read-active.provenance` when degraded: `runtime-metadata`
- `capture-task.status`: `ok | failed`
- `update-due.status`: `ok | failed`
- `update-deadline.status`: `ok | failed`
- `clear-deadline.status`: `ok | failed`
- `move-task.status`: `ok | failed`
- `read-recent-completed.status`: `ok | degraded | failed`
- `read-recent-completed.source`: `live | observational`
- `read-recent-completed.provenance`: `runtime-metadata-summary | live-completed-window`
- `read-recent-activity.status`: `ok | failed`
- `read-recent-activity.source`: `live`
- `read-recent-activity.provenance`: `live-active-updated-window`
- `read-recent-activity.evidence_level`: `current-active-updated-at`
- `read-activity-log.status`: `ok | failed`
- `read-activity-log.source`: `live`
- `read-activity-log.provenance`: `live-activity-log-window`
- `read-activity-log.evidence_level`: `provider-activity-log`
- `read-recent-diff.status`: `ok | degraded | failed`
- `ensure-observation-baseline.status`: `ok | failed`
- `read-recent-diff.source`: `live`
- `ensure-observation-baseline.source`: `live | ephemeral-observation-state`
- `read-recent-diff.provenance`: `ephemeral-active-observation-snapshot`
- `ensure-observation-baseline.provenance`: `ephemeral-active-observation-snapshot`
- `read-recent-diff.evidence_level`: `ephemeral-active-observation-diff`
- `read-recent-diff.coverage_status`: `net_observation_baseline_before_since | partial_baseline_after_since | none`
- `read-due-window.status`: `ok | failed`
- `read-due-window.source`: `live`
- `explain-degraded-state.status`: `ok | failed`
- `explain-degraded-state.provenance`: `runtime-metadata`
- `classify-interaction-signals.status`: `ok | failed`

## Visible response regression gate
- `bin/jen-visible-response-gate` is the deterministic contract for already-captured or simulated chat-turn evidence.
- It performs no external reads or writes.
- It fails direct/tool turns with no visible final response, handled failures with no honest fallback copy, Todoist mutation events that bypass the canonical runtime boundary, and verified-completion wording without matching proof.
- Heartbeat or explicitly suppressed turns may remain silent.
- Use `tests/jen-visible-response-gate.contract.sh` when changing Telegram/direct-chat behavior, Todoist write flows, external read fallback copy, or response-completion policy.
- `classify-interaction-signals.source`: `runtime-metadata`

### Pinned failure classes
- `read-active`: `invalid_argument | adapter_missing | missing_dependency | missing_token | auth_failure | network_failure | request_failure | provider_shape_invalid | rate_limited | state_write_failed`
- `capture-task`: `invalid_argument | adapter_missing | missing_dependency | missing_token | auth_failure | network_failure | request_failure | rate_limited | verification_failed | state_write_failed | mutation_blocked | mutation_confirmation_required | idempotency_collision | unsafe_replay_state | duplicate_existing | semantic_duplicate_confirmation_required | unable_to_verify_duplicates`
- `update-due`: `invalid_argument | adapter_missing | missing_dependency | missing_token | auth_failure | network_failure | request_failure | rate_limited | verification_failed | state_write_failed | mutation_blocked | mutation_confirmation_required | idempotency_collision | unsafe_replay_state`
- `update-deadline`: `invalid_argument | adapter_missing | missing_dependency | missing_token | auth_failure | network_failure | request_failure | rate_limited | verification_failed | state_write_failed | mutation_blocked | mutation_confirmation_required | idempotency_collision | unsafe_replay_state`
- `clear-deadline`: `invalid_argument | adapter_missing | missing_dependency | missing_token | auth_failure | network_failure | request_failure | rate_limited | verification_failed | state_write_failed | mutation_blocked | mutation_confirmation_required | idempotency_collision | unsafe_replay_state`
- `move-task`: `invalid_argument | adapter_missing | missing_dependency | missing_token | auth_failure | network_failure | request_failure | rate_limited | verification_failed | state_write_failed | mutation_blocked | mutation_confirmation_required | idempotency_collision | unsafe_replay_state`
- `read-recent-completed`: `invalid_argument | adapter_missing | missing_dependency | missing_token | auth_failure | network_failure | request_failure | provider_shape_invalid | rate_limited | state_write_failed`
- `read-recent-activity`: `invalid_argument | adapter_missing | missing_dependency | missing_token | auth_failure | network_failure | request_failure | provider_shape_invalid | rate_limited | state_write_failed`
- `read-activity-log`: `invalid_argument | adapter_missing | missing_dependency | missing_token | auth_failure | network_failure | request_failure | provider_shape_invalid | rate_limited | state_write_failed`
- `read-recent-diff`: `invalid_argument | adapter_missing | missing_dependency | missing_token | auth_failure | network_failure | request_failure | provider_shape_invalid | rate_limited | state_write_failed`
- `ensure-observation-baseline`: `invalid_argument | adapter_missing | missing_dependency | missing_token | auth_failure | network_failure | request_failure | provider_shape_invalid | rate_limited | state_write_failed`
- `read-due-window`: `invalid_argument | adapter_missing | missing_dependency | missing_token | auth_failure | network_failure | request_failure | provider_shape_invalid | rate_limited | state_write_failed`
- `explain-degraded-state`: `invalid_argument | state_read_failed | state_invalid | state_corrupt`
- `classify-interaction-signals`: `invalid_argument | state_read_failed | state_invalid | state_corrupt`

### `classify-interaction-signals` success shape
- This command is a metadata-only classifier over already-observed Todoist runtime metadata.
- It must not call Todoist, mutate `/opt/data/state/jen/heartbeat-state.json`, cache task bodies, or create a canonical event stream.
- If the state file does not exist, it returns `status:"ok"` with zero signals.
- `checked_at` is when classification ran.
- `observed_at` inside each signal is the timestamp from the metadata being classified; it may be `null` when metadata has no observation timestamp.
- Success returns:
  - `contract_version:"jen-task-runtime.v1"`
  - `command:"classify-interaction-signals"`
  - `status:"ok"`
  - `source:"runtime-metadata"`
  - `checked_at:<RFC3339 UTC>`
  - `signals:[InteractionSignal]`
  - `summary:{signal_count:number,attention_worthy_count:number,action_eligible_count:number}`
  - `complete:true`
- In the current implementation, completion deltas are at most `aggregated`; they are not `attention-worthy` and never imply user interruption.
- In the current implementation, `attention_worthy_count` and `action_eligible_count` remain `0`.

### `InteractionSignal`
- `signal_id:string` — deterministic from available metadata, for example `runtime-completion-delta:<observed_at>` or `runtime-degradation:<failure_class>:<observed_at>`.
- `level:"observed" | "interpreted" | "aggregated" | "attention-worthy" | "action-eligible"`
- `reason:string`
- `confidence:"low" | "medium" | "high"`
- `source_event_kind:string`
- `observed_at:string|null`
- `source:"runtime-metadata"`
- `requires_user_interruption:boolean`
- `semantic:object` containing only bounded metadata, not task bodies or mirrored task truth.

### `read-active` success shape
- Live success returns a normalized contract shape, not provider passthrough:
  - `contract_version:"jen-task-runtime.v1"`
  - `command:"read-active"`
  - `status:"ok"`
  - `source:"live"`
  - `checked_at:<RFC3339 UTC>`
  - `tasks:[NormalizedTask]`
- On live success, `tasks` is always an array.
- `.tasks.results` is not part of the contract and must not exist.
- Provider-only fields may exist in Todoist adapter responses, but they are not part of the normalized runtime contract unless explicitly listed below.

### `capture-task` duplicate preflight
- `capture-task` must run a semantic duplicate/similarity preflight before any provider `add-task` write when the mutation/idempotency decision is `execute`.
- `duplicate_verified` replay returns the stored verified result and does not re-read duplicate candidates.
- `retry_partial` may continue the recorded partial mutation and does not create a second task.
- For date-bound captures, the runtime must resolve the due string to a deterministic day window before checking duplicates. Supported deterministic forms are currently `today`, `tomorrow`, and `YYYY-MM-DD`.
- If a due string cannot be resolved confidently, the runtime fails closed with `failure_class:"unable_to_verify_duplicates"` and must not call `add-task` or `update-due`.
- Date-bound captures check both a complete `read-due-window` candidate set for the target date and a complete active task read for semantically close active/recurring overlaps.
- Non-date captures check a complete active task read.
- Degraded or incomplete duplicate-check reads fail closed with `failure_class:"unable_to_verify_duplicates"`; degraded `read-active` output is not sufficient for task creation.
- If an exact/near duplicate exists, fail with `failure_class:"duplicate_existing"`.
- If a semantic overlap or partial compound overlap exists, fail with `failure_class:"semantic_duplicate_confirmation_required"` so user-facing copy can ask for confirmation or a precise edit instead of creating silently.
- Duplicate preflight failures include a `preflight` object with bounded candidate evidence; they are handled write-safety outcomes, not adapter crashes.

### `NormalizedTask`
- `id:string|null`
- `content:string|null`
- `description:string|null`
- `project_id:string|null`
- `section_id:string|null`
- `parent_id:string|null`
- `labels:array` — default `[]` when missing, null, or not an array
- `due:object|null`
- `deadline:object|null`
- `priority:number|null`
- `updated_at:string|null`
- `source:"live"`

### `read-recent-activity` success shape
- Live success returns active tasks whose current provider `updated_at` falls inside the requested window.
- This is current-state activity evidence, not a field-level diff. Without a prior task-body cache, the runtime must not claim exactly which field changed.
- Success returns:
  - `contract_version:"jen-task-runtime.v1"`
  - `command:"read-recent-activity"`
  - `status:"ok"`
  - `source:"live"`
  - `observed_at:<RFC3339 UTC>`
  - `since:<RFC3339 UTC>`
  - `until:<RFC3339 UTC>`
  - `tasks:[NormalizedTask]`
  - `summary:{activity_task_count:number}`
  - `evidence_level:"current-active-updated-at"`
  - `limitations:[string]`
  - `complete:true`
  - `provenance:"live-active-updated-window"`
- `limitations` must include `field_level_diff_unavailable_without_task_body_cache`.
- Runtime metadata for the activity window may store only window bounds, observed timestamp, count, source/provenance, and failure metadata. It must not store active task bodies.


### `read-activity-log` success shape
- Live success returns Todoist provider Activity Log events for item/task activity in the requested date window.
- This is official provider event evidence, but it is not a complete field-level before/after diff. Todoist documents Activity Log availability/retention as plan-dependent and item update coverage as limited to `content`, `description`, `due_date`, and `responsible_uid`; before/after values are not guaranteed by this workspace contract.
- Success returns:
  - `contract_version:"jen-task-runtime.v1"`
  - `command:"read-activity-log"`
  - `status:"ok"`
  - `source:"live"`
  - `observed_at:<RFC3339 UTC>`
  - `since:<RFC3339 UTC>`
  - `until:<RFC3339 UTC>` — exclusive upper bound, matching Todoist Activity Log `date_to` semantics
  - `events:[NormalizedActivityEvent]`
  - `summary:{activity_event_count:number}`
  - `evidence_level:"provider-activity-log"`
  - `limitations:[string]`
  - `complete:true`
  - `provenance:"live-activity-log-window"`
- `limitations` must include `activity_log_plan_dependent`, `provider_update_fields_limited`, `before_after_values_not_guaranteed`, and `snapshot_diff_required_for_full_field_comparison`.
- Runtime metadata for the activity-log window may store only window bounds, observed timestamp, count, source/provenance, evidence level, and failure metadata. It must not store event bodies or task bodies.

### `NormalizedActivityEvent`
- `id:string|null`
- `event_type:string|null`
- `object_event_type:string|null`
- `object_type:string|null`
- `object_id:string|null`
- `parent_project_id:string|null`
- `parent_item_id:string|null`
- `initiator_id:string|null`
- `event_date:string|null`
- `extra_data:object` — provider event metadata for this live read only, default `{}`
- `source:"live"`



### `ensure-observation-baseline` success shape
- Ensures the ignored ephemeral active-task observation snapshot is fresh enough for later `read-recent-diff` calls.
- It is read-only against Todoist and calls the `active-snapshot` adapter boundary only when the snapshot is missing, corrupt, stale, or `--force` is supplied.
- Fresh existing baselines are not overwritten unless `--force`; do not use `--force` immediately before day-close diff collection unless intentionally resetting the only useful baseline.
- Runtime metadata remains metadata-only. The ignored ephemeral observation snapshot may store bounded active-task fields, including task content, but it is non-canonical, TTL-bound, and not task truth.
- Success returns:
  - `contract_version:"jen-task-runtime.v1"`
  - `command:"ensure-observation-baseline"`
  - `status:"ok"`
  - `source:"live" | "ephemeral-observation-state"`
  - `observed_at:<RFC3339 UTC>`
  - `baseline_observed_at:<RFC3339 UTC>`
  - `baseline_age_seconds:number`
  - `refreshed:boolean`
  - `refresh_reason:"missing" | "stale" | "corrupt" | "forced" | "fresh"`
  - `force:boolean`
  - `summary:{task_count:number}`
  - `limit:number`
  - `ttl_hours:number`
  - `complete:true`
  - `provenance:"ephemeral-active-observation-snapshot"`
  - `purpose:"baseline_ensure"`
- Snapshot files include `schema_version`, `limit`, `ttl_hours`, `truncated:false`, and normalized bounded active-task fields.

### `read-recent-diff` observation snapshot semantics
- `read-recent-diff` compares the previous observed active-task baseline to the current live active-task state. It does **not** reconstruct arbitrary historical windows and must not be described as a provider event timeline.
- The snapshot baseline is ephemeral and untracked: `${JEN_TODOIST_OBSERVATION_STATE_FILE:-/opt/data/state/jen/todoist-observation-snapshot.json}`. `runtime/jen-home` state must stay ignored by git.
- Default TTL is 48 hours. `--ttl-hours` may tune this within the runtime validation bounds.
- `--until` is accepted only for a live/current-ending window; a past- or future-ending `--until` outside small clock skew is `invalid_argument`, because the command reads current active tasks live.
- The baseline stores bounded active-task observation fields only, and stored baseline tasks are normalized again before diff output so unexpected fields are not echoed: `id`, `content`, `description`, `project_id`, `section_id`, `parent_id`, sorted `labels`, `due`, `priority`, `updated_at`, and `deadline` only when present. This is an observation cache, not task truth.
- Runtime/heartbeat metadata may store only snapshot/diff counts, coverage/freshness, window bounds, observed timestamps, evidence level, and failure metadata. It must not store active task bodies.
- Output must include:
  - `baseline_observed_at`
  - `current_observed_at`
  - `coverage_interval:{from,to}`
  - `requested_window:{since,until}`
  - `coverage_status`
  - `baseline_present` / `baseline_fresh`
  - `diff.changed[]` with `changed_fields`, `before`, and `after` only when a fresh baseline exists
  - `diff.added_to_active_observation[]` and `diff.removed_from_active_observation[]`
- Coverage meanings:
  - `none`: no usable fresh baseline; no exact diff claims. The command may replace the baseline for future observations.
  - `partial_baseline_after_since`: baseline was observed after requested `since`; changes between `since` and baseline are missing.
  - `net_observation_baseline_before_since`: baseline predates requested `since`; output is a net active-observation diff, not a complete intermediate event timeline.
- `removed_from_active_observation` means only “present in previous active snapshot and absent from current active snapshot.” It must not imply deleted, completed, moved, or otherwise resolved unless corroborated by Activity Log/completed-task evidence.

### Runtime metadata boundary
- Runtime-owned metadata lives only at `todoist.runtime` inside `/opt/data/state/jen/heartbeat-state.json`.
- Only `bin/jen-task-runtime` may mutate `todoist.runtime`.
- Runtime metadata is continuity support only, never task truth.
- Do not store mirrored active tasks, backlog snapshots, or cached completed-task bodies in runtime metadata.

### Secret-loading boundary
- The default persistent secret path is workspace-local: `/opt/data/.env`.
- Jen Todoist operations must not depend by default on host-global/shared Todoist env files outside the workspace.
- `TODOIST_API_TOKEN` in the current process environment remains a valid explicit override.
- `TODOIST_ENV_FILE` may be overridden intentionally, but that override is outside the default supported Jen boundary.

### Fallback shapes
- `read-active` degraded fallback is metadata-only and may include only pinned degraded fields such as `status`, `source`, `checked_at`, `note`, and `provenance`.
- If the Todoist adapter exits successfully but emits invalid JSON or a JSON shape that cannot be normalized to an array of active tasks, `read-active` must fail closed into a handled degraded/failure path and must not emit provider passthrough.
- `read-recent-completed` without `--tasks` returns bounded aggregate metadata only, even on live success; it never returns task bodies.
- `read-recent-completed --tasks --since <RFC3339> [--until <RFC3339>]` returns a live completed-task window by completion date. This is allowed to return normalized task bodies because it is a live read, not cached runtime metadata.
- Runtime metadata for the task-body window may store only window bounds, observed timestamp, and count; it must not store completed-task bodies.
- `read-recent-activity --since <RFC3339> [--until <RFC3339>] [--limit N]` returns a live active-task activity window based on current `updated_at`. It is allowed to return normalized task bodies for this request only because it is a live read, not cached runtime metadata.
- `read-activity-log --since <RFC3339> [--until <RFC3339>] [--limit N]` returns a live Todoist Activity Log event window. For this command, `until` is an exclusive upper bound because Todoist Activity Log `date_to` is exclusive. It is allowed to return normalized provider event bodies for this request only because it is a live read, not cached runtime metadata.
- `read-recent-diff --since <RFC3339> [--until <RFC3339>] [--limit N] [--ttl-hours N]` returns an ephemeral active-observation diff when a fresh previous baseline exists; otherwise it returns degraded/no-diff-claim context and refreshes the baseline. It may return task-body before/after values in the live response, but runtime metadata must not cache those bodies.
- `ensure-observation-baseline [--limit N] [--ttl-hours N] [--force]` keeps the ignored ephemeral observation snapshot fresh without overwriting a fresh baseline unless `--force` is supplied. `--force` is operator-only and should not run immediately before day-close diff collection unless intentionally resetting the baseline.
- Runtime metadata for the activity window may store only window bounds, observed timestamp, evidence level, and count; it must not store active task bodies.
- Live aggregate success uses `status: ok` with `source: live` and the same bounded summary shape.
- Observational aggregate fallback uses `status: degraded` with `source: observational` and the same bounded summary shape.
- The pinned aggregate summary schema is:
  - `baseline_present:boolean`
  - `delta_completed_items_total:number`
  - `observed_bucket_count:number`
- The pinned task-window summary schema is:
  - `completed_task_count:number`
- Task-body live windows expose `complete:true`; silent truncation is not allowed.

### `NormalizedCompletedTask`
- `id:string|null`
- `content:string|null`
- `description:string|null`
- `project_id:string|null`
- `section_id:string|null`
- `parent_id:string|null`
- `labels:array` — default `[]` when missing, null, or not an array
- `due:object|null`
- `priority:number|null`
- `added_at:string|null`
- `completed_at:string|null`
- `updated_at:string|null`
- `source:"live"`


## Isolated live smoke test

`bin/jen-todoist-smoke-test [--since RFC3339-UTC] [--until RFC3339-UTC] [--limit N]` is an operator validation helper for the Todoist read surfaces.

- It uses temporary `JEN_TASK_RUNTIME_STATE_FILE` and `JEN_TODOIST_OBSERVATION_STATE_FILE` values and must not touch canonical `/opt/data/state/jen/heartbeat-state.json` or canonical `/opt/data/state/jen/todoist-observation-snapshot.json`.
- It is read-only against Todoist and calls only `bin/jen-task-read` wrapper commands: `activity-log`, `ensure-observation-baseline`, `recent-diff`, and `recent-activity`.
- It emits `contract_version:"jen-todoist-smoke-test.v1"` with component contract status, isolation fields, cleanup result, and warnings.
- Exit/status semantics:
  - `ok`, exit 0 when all required read contracts validate.
  - `partial`, exit 0 only when Activity Log is unavailable/plan-limited/retention-limited as an explicit limitation while baseline/diff/activity contracts validate.
  - `failed`, nonzero for missing token, auth failure, invalid args, provider shape invalid, network/rate-limit/server/request failure, missing dependencies, or other contract validation failures.
- This helper is not part of normal day-close execution and must not be used as a hidden scheduler.

## Minimum reliable commands
- `projects`
- `tasks [limit]`
- `tasks-by-project <project_id> [limit]`
- `task <task_id>`
- `labels`
- `find-task <query> [limit]`
- `task-by-content-exact <content> [limit]`
- `add-task "content" [project_id]`
- `update-task <task_id> [content] [project_id] [labels_csv] [priority]`
- `move-task <task_id> <project_id>`
- `update-due <task_id> <due_string>`
- `update-deadline-date <task_id> <YYYY-MM-DD>`
- `clear-deadline <task_id>`
- `clear-due <task_id>`
- `update-labels <task_id> <label1,label2,...>`
- `close-task <task_id>`
- `reopen-task <task_id>`
- `completed-info`
- `completed-by-completion-date <since_rfc3339> <until_rfc3339> [limit]`
- `active-updated-window <since_rfc3339> <until_rfc3339> [limit]`
- `active-snapshot [limit]`
- `activity-window <since_rfc3339> <until_rfc3339> [limit]`
- `due-window <from_date> <to_date> [limit]`
- `overdue [limit]`
- `clean-overdue-nonreal [limit] [--dry-run]`

## Operational rules
- Use `clear-due` to remove due dates. In API v1 this maps to `due_string: "no date"`.
- Use `update-deadline-date` / `clear-deadline` only behind `bin/jen-task-runtime update-deadline` / `clear-deadline` or an approved runtime wrapper. Deadline writes must be date-only and verified by reading back `.deadline.date` or `.deadline == null`.
- Do not report Todoist as unavailable or degraded based only on generic CLI discovery; only downgrade after the canonical adapter is missing or its invocation fails for a concrete reason.
- Use `bin/jen-task-runtime move-task --task-id <task_id> --project-id <project_id>` for Jen/chat-time project/list changes; `--list-id` is accepted as a Todoist project/list alias. The runtime plans the mutation through the Mutation Gateway, calls adapter `move-task`, and verifies the returned `.project_id`. Do not assume generic task update accepts `project_id`.
- Prefer wrapper commands over inline curl so behavior stays consistent and debuggable.
- Prefer `bin/jen-task-read` for direct operator reads instead of invoking read runtime commands by hand when the wrapper covers the intent.
- Write commands require exact task ids, not fuzzy matching.
- Mutations should do read-after-write verification for the field that changed.
- For obligations, `due` is the intended execution/cadence field and `deadline` is the current-cycle hard cutoff. Recurring hard-obligation deadline maintenance must compute the expected deadline from the current `due.date` and explicit policy, not from the previous `deadline.date`; it must fail closed if the computed deadline would precede the intended execution date unless an explicit policy later permits that exception.
- All live write mutations, including simple low-risk capture, must pass through the Mutation Gateway planning boundary and idempotency store before provider execution. Low-risk capture remains silent/user-fluid, but it is still internally planned, idempotent, and verified.
- If the gateway returns `blocked`, do not execute. If it returns `awaiting_confirmation` or high risk, stop at preview/confirmation instead of executing; confirmed high-risk execution is outside the current hardening scope.
- Treat `Inbox` as capture only.
- Direct-chat concrete task capture is a supported flow: when the user states a concrete task, obligation, or next-day commitment without a fixed time, capture it in Todoist rather than local memory.
- If a direct-chat capture is time-bound enough that Calendar should own it, route there instead of forcing it through Todoist.
- If a direct-chat capture includes an explicit date or relative day-level commitment, `add-task` alone is not a complete capture; follow it with `update-due` using a Todoist-compatible due string that preserves the user's temporal meaning.
- Overdue cleanup should remove non-recurring stale due dates and only move tasks to the configured near-horizon bucket when they are still in the configured capture area. Concrete bucket names are profile/config conventions, not runtime contract.
- Recurring due dates should be treated as real-world cadence unless explicitly reviewed otherwise.
- Do not overwrite a recurring due date with a fixed/non-recurring date during soft-deadline cleanup or bulk date edits. Preserve or re-anchor the recurrence; require an explicit override for intentional recurrence removal.
- Use `--dry-run` before batched cleanup when you want preview without mutation.
- For task capture writes, verify the created or changed task by reading it back from Todoist.

## Direct-chat capture with dates
- Preserve day-level temporal meaning from user language when Todoist is the canonical destination.
- For direct-chat task capture, use `add-task` to create the task, then `update-due` when the user supplied a real date or a relative commitment such as "tomorrow" or "Friday".
- A capture with `content + due` is one semantic mutation (`create task with due`) even though the provider execution is two-step (`add-task`, then `update-due`). If `add-task` succeeds and `update-due` fails, preserve the created task id in idempotency `result_json.partial`, mark the operation failed, and retry only the due update on the existing task for the same semantic mutation. Do not create a second task on retry.
- The contract is semantic preservation, not literal phrase reuse: choose the due string Todoist will interpret correctly for the intended date.
- Read the task back after mutation and verify the due field, not just task existence.

### Capture patterns
- Concrete task with no date → `add-task` only
- Concrete task with day-level date/commitment → `add-task`, then `update-due`, then read-after-write verification
- Fixed-time commitment → route to Calendar instead of Todoist

## Failure handling
- Fail closed on missing token.
- Fail closed on missing required args.
- Validate limit bounds locally.
- Emit JSON errors to stderr for missing dependency, missing token, auth failure, not found, rate limiting, server error, request failure, and verification failure.
- Validate behavior with a read-after-write check when adding new wrapper capabilities.
- Avoid destructive mass changes without explicit user intent.
- For unresolved Todoist runtime failures, Jen should use `bin/jen-todoist-self-heal` to classify, retry only transient failures, sanitize evidence, and open/emit a Moss incident. Credential/auth failures stop for Rodolfo instead of asking Moss to repair credentials.

## Current shape
- API transport is intentionally thin and v1-specific.
- Wrapper semantics stay operational, not productivity-semantic, except for the explicit overdue cleanup helper that encodes the current Todoist rules.
- `completed-info` is a read-only aggregate signal sourced from `POST /api/v1/sync`; it returns `completed_info` counts, not a list of recently completed tasks.
- `completed-by-completion-date` is a read-only live task-body signal sourced from `GET /api/v1/tasks/completed/by_completion_date`; use it for Jen's recent-completion awareness when task bodies matter.
- `active-updated-window` is a read-only live active-task signal sourced from `GET /api/v1/tasks` and filtered by current `updated_at`; use it for recent edit/activity awareness when task bodies matter.
- `active-snapshot` is a read-only live active-task observation snapshot sourced from paginated `GET /api/v1/tasks`; it must return the complete-window shape `{results,next_cursor:null,complete:true,page_count}` for snapshot diff consumers.
- `activity-window` is a read-only live provider event signal sourced from `GET /api/v1/activities` and filtered to Todoist item/task events in the requested date window. Use it for official event evidence, while preserving its plan/retention and field-coverage limitations.
- `due-window` is a read-only live active-task signal filtered by `due.date`; use it for intended-execution/cadence pressure before/after the current day, not as proof of hard-deadline pressure unless paired with `deadline` evidence.
- Commands that expose live task windows must either paginate to completion or expose explicit incomplete/cursor metadata; current supported `completed-by-completion-date` and `due-window` behavior paginates to completion.
- If Jen derives a delta from repeated `completed-info` snapshots, that delta is best-effort observational state only, not an audit log or canonical event stream.
- REST v2 and Sync v9 should still be treated as unavailable unless revalidated later.
