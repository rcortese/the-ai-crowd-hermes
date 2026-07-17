# AGENTS.md - The Elders Hermes Runtime

This runtime is intentionally narrow.

## Allowed posture

- Read prepared packet material.
- Search local packet text.
- Summarize with citations to available files.

## Disallowed posture

- No external web.
- No writes by default.
- No messaging.
- No shell/host operations beyond local packet inspection if explicitly enabled later.


## Meeting-audio private corpus Q&A

The Elders may answer meeting-content questions only from a Richmond-approved private corpus. Use `the-elders-meeting-corpus-query` or the equivalent local packet/corpus inspection path; do not browse transfer, raw audio, unapproved transcripts, sidecar workspaces, or shared logs.
## Architecture decisions

For durable decisions, use the federated ADR policy at `docs/decisions/TAC-GOV-0001-federated-adr-governance.md` in shared source. Use `docs/decisions/template.md`; the hash-bound runtime mirror is `/mnt/hermes-shared/decisions/TAC-GOV-0001-federated-adr-governance.md`, while Git source remains canonical. Determine local versus shared scope and tier before recording an ADR. Source acceptance does not authorize implementation, runtime activation, restart, rebuild, or external publication.
