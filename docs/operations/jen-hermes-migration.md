# Jen Hermes migration scaffold

Status: public scaffold only.

This file defines the public, product-level migration shape for Jen on Hermes.
It intentionally excludes private runtime evidence, account identifiers, channel
bindings, provider state, backup paths, cron job ids, smoke-test transcripts,
and operator/person-specific details.

## Public phases

1. Scaffold the Jen agent container and public/private mount boundary.
2. Configure public-safe capability contracts for task, calendar, and messaging surfaces.
3. Keep all provider credentials, live validation evidence, rollback artifacts,
   and delivery/channel bindings in Jen's private repository or ignored runtime state.
4. Require review gates before enabling any live external write, messaging delivery,
   credential mutation, or gateway/container cutover.

## Public review gates

- Boundary gate: public files contain only product contracts, examples, and safe placeholders.
- Capability gate: public manifests describe classes of capability, not live account state.
- Runtime gate: live validation evidence and rollback paths are private artifacts.
- Mutation gate: external writes require private approval, idempotency, and rollback evidence.

## Private evidence

Private migration notes, live runtime identifiers, smoke-test evidence, channel
configuration, and rollback details belong in Jen's private repo. The public
repo must not act as an index to those private artifacts.
