# Moss memory contract

Moss memory on Hermes is split between public contracts, Moss-owned private versioned state, and unversioned runtime state.

## Public memory-equivalent material

Public files may contain:

- durable operating rules;
- architecture and ownership contracts;
- public-safe runbooks;
- validation and migration procedures;
- examples with placeholder values.

## Moss private versioned memory

`agents/moss/private/` is the approved nested private Git repo for versionable Moss private state.

Initial shape:

```text
agents/moss/private/
├── standing/
├── memory/
├── operations/
├── corrections/
├── incidents/
├── private-infrastructure/
├── runbooks/
└── indexes/
```

`indexes/` may be generated from source files and should not become the source of truth.

Private versioned memory may contain:

- the operator-specific technical preferences relevant to Moss;
- local hostnames, paths, and topology when needed for Moss operations;
- operational breadcrumbs and redacted evidence summaries;
- self-improving corrections relevant to Moss;
- private runbooks and incident summaries.

## Never-version runtime state

Do not version these in public or private Git:

- real `.env` files;
- auth files, tokens, OAuth/provider state, cookies;
- session state;
- caches;
- runtime databases;
- raw dumps;
- log dumps;
- secrets or private keys.

## Split rule

`agents/moss/private/` is the Moss private root. A subdomain becomes a separate private repository only when it has an independent lifecycle, deploy surface, ownership boundary, risk boundary, or sharing boundary.

## Ownership boundary

This contract covers Moss private memory, not universal private memory for The AI Crowd. Jen, Denholm, Richmond, Roy, and The Elders retain their own domain ownership. Moss may provide technical support, but it must not host or own another domain's private state by default.

If Moss stores a private reference for another domain, the card/handoff must record the decision owner, reason, return path, and split-rule rationale.

## Migration rule

Do not bulk-copy OpenClaw memory into the public Hermes scaffold or into `agents/moss/private/`. Classify by data class and owner, redact where needed, then import only curated slices.

## Source-of-truth rule

Generated indexes and recall stores are not source of truth. Prefer versioned docs, Moss private memory files, project repos, and validated runtime state.
