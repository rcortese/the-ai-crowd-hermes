# Documentation index

This index is the public reader path for the Hermes scaffold.

## Recommended reader path

1. Start with the repository purpose and boundaries in [`../README.md`](../README.md).
2. Read the architecture overview in [`architecture/system-overview.md`](architecture/system-overview.md).
3. Review public/private safety in [`architecture/public-private-boundary.md`](architecture/public-private-boundary.md) and [`decisions/0001-public-scaffold-private-state.md`](decisions/0001-public-scaffold-private-state.md).
4. Review capability and mount policy in [`architecture/mounts-and-capabilities.md`](architecture/mounts-and-capabilities.md) and [`../ops/policies/`](../ops/policies/).
5. Review private memory scaffolding in [`operations/private-memory-migration.md`](operations/private-memory-migration.md).
6. Review cutover and capability-lane controls in [`operations/cutover-checklist.md`](operations/cutover-checklist.md), [`operations/capability-lanes.md`](operations/capability-lanes.md), [`operations/private-mount-boundary.md`](operations/private-mount-boundary.md), and [`operations/openclaw-transition.md`](operations/openclaw-transition.md).
7. Run validation from [`VALIDATION.md`](VALIDATION.md).

## Core architecture

- [`architecture/system-overview.md`](architecture/system-overview.md): system shape and reader overview.
- [`architecture/agent-container-model.md`](architecture/agent-container-model.md): container/runtime model.
- [`architecture/moss-architecture.md`](architecture/moss-architecture.md): layered Moss model.
- [`architecture/mounts-and-capabilities.md`](architecture/mounts-and-capabilities.md): mounted/wrapped capability model.
- [`architecture/kanban-workflow.md`](architecture/kanban-workflow.md): Hermes-native work item model and lifecycle contract.

## Runbooks

- [`PRODUCTION.md`](PRODUCTION.md): production template and private deployment posture.
- [`ROLLBACK.md`](ROLLBACK.md): rollback template.
- [`HARDENING.md`](HARDENING.md): hardening backlog.
- [`VALIDATION.md`](VALIDATION.md): public-safe validation commands.
- [`migration-viability.md`](migration-viability.md): viability notes.
- [`operations/cutover-checklist.md`](operations/cutover-checklist.md): not-production-live and cutover evidence checklist.
- [`operations/capability-lanes.md`](operations/capability-lanes.md): safe lanes for messaging, SSH, Docker/Compose, project mounts, private memory, and OpenClaw transition support.
- [`operations/private-mount-boundary.md`](operations/private-mount-boundary.md): private/public mount visibility rule for private deployments.
- [`operations/openclaw-transition.md`](operations/openclaw-transition.md): OpenClaw fallback matrix; heartbeat/reminders remain OpenClaw-owned.

## Schemas and examples

- Schemas live in [`../schemas/`](../schemas/).
- Public sample objects live in [`../examples/`](../examples/).
- Kanban lifecycle and resumption rules live in [`architecture/kanban-workflow.md`](architecture/kanban-workflow.md).
- Example kanban cards live in [`../examples/kanban/`](../examples/kanban/).
- Example handoffs live in [`../examples/handoffs/`](../examples/handoffs/).
- Example review gates live in [`../examples/review-gates/`](../examples/review-gates/).
- Capability examples and tool inventories live in [`../ops/manifests/`](../ops/manifests/).

## Validation

Run `./tests/run-all.sh` for public-safe checks. Run `./tests/smoke-deploy.sh` only in an environment where Docker access is authorized.
