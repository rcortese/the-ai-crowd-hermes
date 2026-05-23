# Moss wrapper contract

Wrappers are the preferred path for high-impact operations such as SSH, Docker/Compose control, provider access, or external messaging.

## Wrapper requirements

A wrapper should provide:

- clear purpose and owner;
- explicit target/scope;
- dry-run or preflight mode where possible;
- evidence output suitable for kanban or reports;
- no embedded secrets;
- refusal when required mounts/credentials are absent;
- narrow behavior instead of general unrestricted shell access.

## Current public wrappers

These wrappers are public-scaffold safe and do not grant new private authority.

- `preflight-template.sh`: generic no-op style preflight skeleton.
- `workspace-dirty-watch.sh`: read-only Git workspace inspection.
- `messaging-dry-run.sh`: dry-run external messaging evidence; live sends are blocked in public scaffold.
- `ssh-readonly-preflight.sh`: dry-run SSH capability evidence using private-ref placeholders; no host connection in public scaffold.
- `compose-readonly-preflight.sh`: read-only local Compose/repo preflight; no host Docker control or mutation.

## Not enabled by these wrappers

The public wrappers do not enable:

- SSH keys or live SSH access;
- Docker socket or host container control;
- provider credentials;
- external message delivery;
- OpenClaw gateway/config/session/cron tools;
- Heartbeat/reminder migration into Hermes.

Live private capabilities require private overlays, allowed-target policy, review gates, validation evidence, and operator approval when the action is sensitive or mutating.
