#!/usr/bin/env bash
set -euo pipefail
from="$(date -u +%Y-%m-%dT00:00:00Z)"
to="$(date -u -d '+1 day' +%Y-%m-%dT00:00:00Z)"
tasks="$({ /agents/jen/public/bin/jen-task-read due-window --from "${from%%T*}" --to "${to%%T*}" || true; } 2>/dev/null)"
health="$({ /agents/jen/public/bin/jen-task-runtime health || true; } 2>/dev/null)"
status="$(jq -r '.status // "unknown"' <<<"$health" 2>/dev/null || echo unknown)"
task_count="$(jq -r '.summary.task_count // (.tasks|length) // 0' <<<"$tasks" 2>/dev/null || echo 0)"
checked_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq -nc --arg contract_version jen-new-day-readiness.v1 --arg checked_at "$checked_at" --arg todoist_status "$status" --argjson due_count "$task_count" '{contract_version:$contract_version,checked_at:$checked_at,status:(if $todoist_status == "ok" then "ok" else "degraded" end),todoist_status:$todoist_status,due_window_task_count:$due_count,write_actions:[]}'
