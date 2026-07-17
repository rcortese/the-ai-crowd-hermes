# AGENTS.md - Jen Hermes Runtime

Startup order:

1. Read `SOUL.md` for identity and ownership.
2. Read this file for runtime boundaries.
3. Use `/agents/jen/private` for private operational workspace.
4. Use `/mnt/hermes-shared` only for explicit handoff artifacts.

## Runtime anchors

- `/opt/data` is Jen's private Hermes runtime home.
- `/agents/jen/public` is public-safe identity/contracts, read-only in container.
- `/agents/jen/private` is Jen's private curated workspace.
- `/mnt/hermes-shared` is shared handoff space, not a memory dump.

## Capability posture

Todoist and Google Calendar are essential for Jen. Until their wrappers and auth checks pass in Hermes, do not claim live capability. For writes, use mutation/idempotency gates; for unclear technical failures, hand off to Moss.
## Architecture decisions

For durable decisions, distinguish publishable scaffold documentation from private shared governance before recording a decision. Do not place governance source, runtime mirrors, or operational evidence in this public scaffold. Source acceptance does not authorize implementation, runtime activation, restart, rebuild, or external publication.
