# Architecture decision records

This directory is the canonical location for shared The AI Crowd architecture decision records (ADRs).

## Governance

`TAC-GOV-0001` defines the accepted federated governance contract. Its implementation controls are tracked separately from this normative acceptance.

## Index

| ID | Title | Decision status | Implementation status | Tier | Owner | Record |
|---|---|---|---|---|---|---|
| `0001` | Public scaffold, private state | accepted (legacy format) | unknown | unclassified legacy | not recorded | [0001-public-scaffold-private-state.md](0001-public-scaffold-private-state.md) |
| `TAC-GOV-0001` | Federated architecture decision record governance | accepted | not-started | T2 | Denholm | [TAC-GOV-0001-federated-adr-governance.md](TAC-GOV-0001-federated-adr-governance.md) |

The legacy `0001` record remains valid provenance. It is an explicit migration candidate and is not silently renumbered or rewritten by the founding policy.

## New records

1. Read `TAC-GOV-0001`.
2. Decide whether an ADR is required and determine its scope and tier.
3. Copy [template.md](template.md).
4. Allocate an unused immutable ID in the correct authoritative repository.
5. Record owners and explicit outcomes; silence is not consent for T2/T3.
6. Keep implementation and verification state separate from decision acceptance.
7. Add the record to this index and run the repository validator when available.

Indexes aid discovery and do not duplicate normative ADR text.
