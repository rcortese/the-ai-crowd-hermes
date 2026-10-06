# OpenClaw transition support

Status: public scaffold contract
Owner: Moss

Moss-on-Hermes must not silently inherit OpenClaw runtime authority. During migration, OpenClaw remains the fallback for OpenClaw-native behavior unless a reviewed Hermes wrapper or replacement exists.

## Non-migrated by decision

Heartbeat, reminder, and OpenClaw cron behavior remain in OpenClaw. The Hermes scaffold must not reimplement, schedule, or claim ownership of the OpenClaw heartbeat concept.

When a task depends on heartbeat/reminder behavior, route it to the current OpenClaw mechanism or record it as blocked for Hermes until the operator explicitly authorizes a different design.

## Runtime task matrix

| OpenClaw task | Hermes default | Requirement before Hermes can perform it |
|---|---|---|
| Config/schema inspection | not assumed | reviewed admin wrapper or explicit operator action |
| Config mutation | not assumed | explicit operator approval, wrapper, backup/rollback evidence |
| Gateway restart/reload | not assumed | explicit operator approval and rollback/impact note |
| Cron/job inventory | OpenClaw fallback | reviewed read-only inventory wrapper |
| Heartbeat/reminders | OpenClaw only | out of Hermes scope by current decision |
| Session/subagent diagnostics | OpenClaw fallback | Hermes-native equivalent or reviewed bridge |
| Lossless/context recall | OpenClaw fallback | Hermes-native equivalent or reviewed bridge |
| Channel/messaging delivery | disabled | private messaging lane approval |

Lossless/context recall health remains an OpenClaw fallback surface until Hermes has an explicit equivalent or reviewed bridge.

## Fallback record

Every cutover or parity rehearsal should record:

```text
openclaw_fallback: available|not_available
heartbeat_owner: OpenClaw
cron_owner: OpenClaw unless explicitly migrated later
runtime_admin_path: OpenClaw Moss|reviewed wrapper|blocked
notes: <public-safe summary>
```

## Documentation rule

Public Hermes docs may mention OpenClaw runtime tasks only as migration/fallback surfaces. They must not instruct Hermes Moss to run OpenClaw gateway/config/session/cron operations unless the corresponding wrapper and private policy exist.
