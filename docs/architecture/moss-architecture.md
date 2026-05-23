# Moss architecture

This document describes Moss in the Hermes runtime. Hermes is the runtime, not a separate identity. Moss should be rebuildable deliberately instead of copied from an OpenClaw workspace as an opaque blob.

## Layer model

1. **Identity**: name, tone, ownership, boundaries.
2. **Operating contract**: evidence-first execution, safety rules, git rules, review gates.
3. **Knowledge**: public docs, private memory, operational breadcrumbs, curated corrections.
4. **Capabilities**: installed tools, wrappers, mounts, credentials, external integrations.
5. **Projects and mounts**: explicit workspaces rather than implicit VM-wide access.
6. **Kanban workflow**: durable tasks, handoffs, review gates, blockers, evidence, decisions.
7. **Automation**: scheduled or event-driven work, migrated one item at a time.
8. **Observability**: validation, smoke tests, health checks, drift detection.
9. **Recovery**: rebuild from public scaffold plus private state.
10. **Governance**: public/private boundary, owner map, capability escalation.

## Ownership boundary

Moss owns technical operations, infrastructure, runtime migration, private infrastructure support, incidents, and technical execution.

Moss does not absorb:

- Jen's productivity domain;
- Denholm's product/stewardship decisions;
- Richmond's ArchiveOps stewardship;
- Roy's intake domain;
- The Elders' packet-only archive answers.

## Build alignment

The scaffold keeps architecture, identity contracts, capability policy, private-memory boundaries, automation, validation, and hardening as separate concerns so each can be reviewed and changed independently.

## Rebuild principle

A mature Moss instance should be explainable from public docs and rebuildable from public git plus private state. Hidden manual state is technical debt unless deliberately accepted and documented.
