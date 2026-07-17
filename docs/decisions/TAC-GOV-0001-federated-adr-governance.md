# TAC-GOV-0001: Federated architecture decision record governance

- **ID:** `TAC-GOV-0001`
- **Decision status:** `accepted`
- **Implementation status:** `not-started`
- **Date:** 2026-07-14
- **Effective date:** 2026-07-14
- **Tier:** `T2`
- **Scope:** shared The AI Crowd governance contract
- **Decision scope key:** `shared.adr-governance`
- **Accountable owner:** Denholm (shared product/contract stewardship)
- **Technical steward:** Moss (schema, template, index, and validator only)
- **Reserved authority:** Rodolfo — `approved` by explicit operator instruction on 2026-07-14
- **Materially affected owners:** Denholm, Jen, Moss, Richmond, Roy, The Elders
- **Acceptance outcomes:** Denholm — `consent`; Jen — `consent`; Moss — `consent` limited to technical stewardship; Richmond — `consent`; Roy — `consent`; The Elders — `consent`
- **Independent review:** `not-applicable` (T2)
- **Ratified normative artifact:** SHA-256 `e66f371606aa1aed0989e94687c554570b79e152fd2784fd3a7626cd38cf8e73`; all outcomes recorded 2026-07-14
- **Supersedes:** none
- **Superseded by:** none

## Context

The AI Crowd already has decision-like records: an isolated public ADR, private ADRs, architecture packets, reports, runbook sections, and Kanban evidence. The missing capability is a uniform contract defining when a decision is an ADR, where its normative record lives, who may decide it, how its lifecycle is tracked, and how it is discovered or superseded.

Without that contract, durable decisions can acquire competing normative sources, cross persona boundaries without explicit consent, lose implementation provenance, or become stale without an owner. A central workflow service would add disproportionate coupling at the current scale.

This ADR establishes a Git-native, federated, proportional governance model. It governs decision records; it does not grant implementation, deployment, publication, or runtime-lifecycle authorization.

## Decision

### 1. One canonical normative record per decision scope

A durable decision has exactly one canonical normative ADR.

- Shared contracts and cross-persona decisions live in `docs/decisions/` in the authoritative shared The AI Crowd source repository.
- Persona-local decisions live in `decisions/` in that persona's authoritative private source repository.
- Reports, runbooks, Kanban cards, review packets, implementation plans, and evidence may reference an ADR but do not replace it.
- Hermes profiles are execution modes, not authority-bearing personas, and do not receive ADR namespaces.

Indexes are discovery aids. They are not independent normative copies.

### 2. Qualification rule

Create or supersede an ADR when a decision is durable and materially affects architecture or system contracts; authority, ownership, or persona boundaries; data, identity, security, privacy, or destructive capability; obligations between personas or shared services; high-blast-radius or difficult-to-reverse operations; material policy exceptions; or choices whose repeated rediscovery or drift is costly.

Do not create an ADR for routine implementation, reversible tuning, incident chronology, unadopted experiments, or task tracking unless one of those material conditions is present.

### 3. Immutable identifiers

- Shared ADRs use `TAC-<DOMAIN>-NNNN`.
- Persona-local ADRs use `<PERSONA>-<DOMAIN>-NNNN`.
- IDs are never reused, including after rejection or withdrawal.
- Renaming a file does not change its ID.
- A material normative change after acceptance requires a new ADR that supersedes the old one.

Domains are concise stable labels such as `GOV`, `ARCH`, `DATA`, `SEC`, `OPS`, or `IDENTITY`. The technical steward maintains the allowed shared domain list without changing decision authority.

### 4. Proportional tiers and subsidiarity

The closest legitimate domain owner decides. Central roles participate only when their domain or reserved authority is materially implicated.

#### T1 — local and reversible

Use for durable, persona-local, reversible decisions with no shared contract or material shared risk.

- Required acceptance: accountable owner.
- Required review: none by default.
- Record may be concise, but must include the common required fields.

#### T2 — shared contract or material boundary

Use for shared contracts, cross-persona behavior, persona boundaries, or substantial durable architecture.

- Required acceptance: accountable owner plus each owner receiving a material obligation, constraint, exposure, operational burden, risk, or loss of autonomy.
- Silence is not consent.
- An objection blocks only within the objector's legitimate authority boundary.
- Missed response deadlines leave the outcome unresolved or escalated; they do not create approval.

#### T3 — high impact or reserved authority

Use for security, privacy, identity, destructive or irreversible action, high blast radius, policy exceptions, or reserved production authority.

- Required acceptance: accountable owner, materially affected owners, and the applicable reserved authority.
- Required review: independent review of the exact artifact version.
- An exception to independent review must itself be explicitly authorized, scoped, expiring, and recorded.

Denholm, Moss, and Rodolfo do not form a default serial approval chain. Their participation follows the rules above.

### 5. Roles and separation of authority

- **Accountable owner:** owns the normative lifecycle, acceptance outcomes, review triggers, supersession, and ownership transfer.
- **Materially affected owner:** consents only where the decision creates material impact inside that owner's legitimate boundary.
- **Technical steward:** maintains templates, indexes, schema/validator behavior, and mechanical quality. The steward cannot approve substance, override an owner, or reinterpret reserved authority.
- **Independent reviewer:** checks the exact artifact version for the assigned lane. Review is not decision authority.
- **Implementer:** executes only under separate authorization and records evidence. Acceptance is not authorization to implement.
- **Verifier:** checks implementation evidence and is identified when implementation status becomes `verified`.
- **Reserved authority:** decides only matters explicitly reserved to that authority.

A person or persona may hold multiple roles only when the ADR records that fact and the tier permits it. T3 independent review cannot be self-review.

### 6. Decision lifecycle is separate from implementation lifecycle

Allowed decision statuses are `proposed`, `accepted`, `rejected`, `deprecated`, `superseded`, and `withdrawn`.

Allowed implementation statuses are `not-started`, `in-progress`, `partially-implemented`, `implemented`, `verified`, `blocked`, `rolled-back`, `not-applicable`, and `unknown`.

Acceptance records a normative decision. It does not prove execution. Implementation updates must not rewrite accepted normative substance.

`verified` requires dated evidence, an identified verifier, and an immutable or stable evidence pointer. If current evidence cannot be established, use `unknown` or another truthful status.

### 7. Required ADR content

Every ADR records immutable ID and title; decision and implementation statuses; date, tier, and scope; accountable owner and technical steward when applicable; materially affected owners and explicit acceptance outcomes; reserved-authority outcome when applicable; context and decision; consequences and alternatives; safe implementation/evidence pointers; review triggers; supersession links; and verification date/verifier when status is `verified`.

T1 records may keep sections short. T2 and T3 records must make obligations and authority outcomes explicit.

### 8. Promotion from local to shared scope

When a persona-local decision becomes materially cross-persona:

1. retain the local ADR as provenance;
2. create a new shared ADR with a new `TAC-*` ID;
3. reference the local ADR using a safe stable pointer;
4. state exactly which local clauses the shared ADR incorporates or supersedes;
5. update reciprocal links where confidentiality permits.

Do not maintain synchronized public and private normative variants. Publication does not transfer ownership of private evidence or local-domain authority.

### 9. Confidentiality and public/private composition

Normative obligations that affect a shared participant cannot be hidden in a private annex.

Private annexes may hold topology, credentials references, private evidence, incident detail, or personal context. The shared ADR must contain enough public-safe normative text for every affected participant to understand obligations, authority, risk, and verification requirements.

Never embed credentials, tokens, raw private logs, private database contents, or personal transcripts in an ADR.

### 10. Ownership continuity and review triggers

The accountable owner maintains lifecycle accuracy and acts on declared review triggers. If ownership changes, the ADR records the transfer. If no successor exists, mark the ADR ownerless and escalated in the index rather than silently treating it as current.

Review is event-driven by default: material scope/authority/risk/dependency changes; contradictory evidence; exception expiry; relevant incident or audit finding; owner departure/transfer; or proposed normative change. Universal calendar review is not required initially.

### 11. Lightweight validation and discovery

The shared repository will use a lightweight validator for shared ADRs. Persona repositories may reuse the same rules proportionally.

Validation checks mechanical properties only: unique/well-formed IDs, legal statuses and tiers, tier-required fields, index coverage, links, reciprocal supersession where applicable, explicit outcomes required for `accepted`, and dated evidence plus verifier for `verified`.

Validator success does not approve substance. Initial governance requires no ADR database, central workflow engine, mandatory panel for every decision, or universal review service.

### 12. Adoption of this founding policy

This founding T2 ADR is accepted only after its accountable owner and all materially affected owners have explicit outcomes recorded, together with the operator's reserved-authority decision. Until then its decision status remains `proposed`, regardless of architectural-panel consensus.

Once accepted, the effective version is the exact committed artifact identified by commit hash. Later normative changes require supersession under this policy.

## Consequences

### Positive

- Durable decisions gain one discoverable normative source.
- Persona autonomy and cross-persona consent are explicit and proportional.
- Acceptance, execution authorization, implementation, and verification remain distinguishable.
- Existing records retain provenance and can be migrated selectively.
- Git history and lightweight validation provide traceability without a new service.

### Costs and trade-offs

- Owners must record explicit outcomes for T2/T3 decisions.
- Initial indexing and selective migration require bounded effort.
- Private evidence needs careful public-safe references.
- Mechanical validation cannot replace architectural judgment.

## Alternatives considered

- **Keep current informal records:** rejected because competing normative sources and lifecycle ambiguity are already present.
- **One central ADR repository or workflow service:** rejected initially as disproportionate coupling and a central bottleneck.
- **Require Denholm, Moss, and Rodolfo to approve every ADR:** rejected because it violates subsidiarity and conflates stewardship with authority.
- **Duplicate shared decisions into every persona repository:** rejected because synchronized normative copies drift.
- **Retrofit every historical decision immediately:** rejected because selective, provenance-aware migration is safer.

## Initial implementation pointers

- Shared index: `docs/decisions/README.md`
- Shared template: `docs/decisions/template.md`
- Existing legacy ADR: `docs/decisions/0001-public-scaffold-private-state.md`
- Validator and migration inventory: to be implemented under a separately reviewed adherence plan

## Review triggers

See Decision §10. Any proposed change to qualification, tiers, authority, canonical locations, promotion, confidentiality, or lifecycle is normative and requires a superseding ADR.
