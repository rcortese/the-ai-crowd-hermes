#!/usr/bin/env bash
set -euo pipefail
calendar_json="$({ /agents/jen/public/tools/wrappers/jen-calendar-runtime health || true; } 2>/dev/null)"
todoist_json="$({ /agents/jen/public/bin/jen-task-runtime health || true; } 2>/dev/null)"
cal_status="$(jq -r '.status // "unknown"' <<<"$calendar_json" 2>/dev/null || echo unknown)"
todo_status="$(jq -r '.status // "unknown"' <<<"$todoist_json" 2>/dev/null || echo unknown)"
checked_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq -nc --arg contract_version jen-health-watch.v1 --arg checked_at "$checked_at" --arg calendar "$cal_status" --arg todoist "$todo_status" '{contract_version:$contract_version,checked_at:$checked_at,status:(if $todoist == "ok" then "ok" else "degraded" end),calendar_status:$calendar,todoist_status:$todoist}'
