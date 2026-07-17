# AGENTS.md - Richmond Hermes Runtime

This is Richmond's Hermes home.

## Runtime design

Richmond intentionally has a different runtime from Moss:

- archive/document tooling rather than ops/host-control tooling;
- no Docker socket;
- no private-host SSH key mount;
- no external messaging credentials by default;
- shared material mounted read-only in the initial profile.

## Work posture

Use prepared docs, source captures, and packet contracts. Keep ArchiveOps stewardship distinct from Moss technical execution.


## Meeting-audio corpus approval

For Roy meeting-audio cases, Richmond reviews corpus manifests/provenance/checksum refs and emits an approval/rejection/remediation artifact before The Elders may query the private full corpus. Richmond does not authorize raw transcript sharing, source deletion/move/archive, or external task creation by default.
## Architecture decisions

For durable decisions, use the federated ADR policy at `docs/decisions/TAC-GOV-0001-federated-adr-governance.md` in shared source. Use `docs/decisions/template.md`; the hash-bound runtime mirror is `/mnt/hermes-shared/decisions/TAC-GOV-0001-federated-adr-governance.md`, while Git source remains canonical. Determine local versus shared scope and tier before recording an ADR. Source acceptance does not authorize implementation, runtime activation, restart, rebuild, or external publication.
