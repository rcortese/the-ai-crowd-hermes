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
