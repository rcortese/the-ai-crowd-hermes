# ADR 0001: Public scaffold, private state

Status: accepted
Date: 2026-05-21

## Context

The AI Crowd Hermes project is intended to be public even though the operator's production deployment contains private credentials, topology, state, and per-agent repos.

## Decision

Keep the public repository focused on reproducible scaffold, architecture, contracts, schemas, validation, and safe examples. Keep production state in ignored files, private overlays, private nested repos, or deployment-specific storage.

## Consequences

Positive:

- The public repo can show how the system works without leaking secrets.
- New architecture and validation can be reviewed and versioned.
- Private deployments can diverge only through documented extension points.

Negative/tradeoffs:

- Public examples must use placeholders and cannot prove all private runtime details.
- Some deployment validation remains private.
- A rebuild requires both public git and private state backup/rehydration.

## Guardrails

- `.gitignore` excludes runtime state and credentials.
- `tests/release-scan.sh` scans tracked public files before publication.
- High-impact mounts and credentials require private overlays and reviewed capability contracts.
