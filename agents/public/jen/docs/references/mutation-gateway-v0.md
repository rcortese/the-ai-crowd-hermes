# Mutation Gateway v0

## Purpose

`bin/jen-mutation-gateway` is the canonical planning and validation boundary for external mutations.

It implements the first P0 slice from `jen-product-evolution-plan-2026-04-25.md`: before Jen mutates Todoist, Google Calendar, filesystem-backed state, or another persistent system, the intended operation must become a structured mutation record with risk classification, confirmation posture, idempotency key, and audit reference.

v0 is intentionally safe: it **does not execute provider writes**. It validates and classifies mutation intent so downstream runtimes can refuse unsafe direct writes and tests can reason about the intended operation before execution exists.

## Command

```bash
bin/jen-mutation-gateway schema
bin/jen-mutation-gateway plan [file|-] [--pretty]
```

`plan` reads a JSON mutation draft and emits one canonical JSON record.

## Contract version

`jen-mutation-gateway.v0`

## Minimum record fields

The planned record contains:

- `intent_id`
- `user_request_ref`
- `operation_type`
- `target_system`
- `canonical_object_type`
- `external_object_id`
- `risk_level`
- `risk_reasons`
- `idempotency_key`
- `preview`
- `requires_confirmation`
- `pre_state`
- `mutation_payload`
- `post_state`
- `verification_result`
- `status`
- `audit_log_ref`
- `planned_at`
- `contract_version`

## Risk policy

### Low

Examples:

- create simple non-recurring Todoist task;
- create focus block with no guests;
- create one-off reminder;
- rename item recently created by Jen.

Low operations do not require user confirmation by default, but still require idempotency and verification before any future executor may say “done”.

### Medium

Examples:

- mutate an existing non-recurring task;
- move/update a simple event without guests;
- create duplicate-prone events such as lunch/focus blocks when no ambiguity is detected.

Medium operations may run only after duplicate/pre-state checks. Ambiguity should escalate to confirmation.

### High

Examples:

- calendar event with attendees;
- past calendar event;
- recurrence-sensitive operation that is not immediately blocked;
- batch/multi-item mutation.

High operations require explicit confirmation.

### Blocked

Examples:

- update/delete/complete/move without `pre_state`;
- ambiguous destructive recurring task operation;
- calendar invite without manual confirmation;
- destructive recurrence scope such as whole-series deletion;
- oversized bulk operation.

Blocked operations are valid planning outputs, not process errors. They must not execute.

## Idempotency

If `intent_id` or `idempotency_key` is not supplied, the gateway derives stable hashes from the semantic operation fields.

The runtime-level `normalized_hash` used with `bin/jen-idempotency-store` must identify the semantic mutation, not a runtime attempt. It may include only target system, operation type, canonical object type, relevant external object id, normalized semantic payload, and required semantic `pre_state`. It must not include timestamps, transient status, verification result, provider response bodies, retry counters, mutable audit paths, or stdout wrapper metadata.

Duplicate replay may become synthetic success only from a matching `verified` record with compatible result JSON and schema. `planned`, `executed`, `failed`, `awaiting_confirmation`, `blocked`, `collision`, missing result, or old/incompatible schema must not become synthetic success.

Persistent idempotency state is owned by `bin/jen-idempotency-store` under `.openclaw/state/idempotency/` by default:

```text
.openclaw/state/idempotency/
  messages.sqlite
  intents.sqlite
  external_objects.sqlite
```

The store supports `put`, `get`, and `check` for message, intent, and external-object scopes. It records normalized hash, user/channel refs, target system, external object id, status, audit log ref, result JSON, timestamps, and TTL. Matching hash is a duplicate; same key with a different hash is a collision and must not execute automatically.

## High-risk confirmation boundary

For the current live-write hardening scope, high-risk operations are preview-only. They may produce a gateway plan and persist an `awaiting_confirmation` state, but they must not execute provider writes.

A future high-risk execution phase must define a confirmation reference/token, bind the confirmation to the approved preview, define expiration and replay rules, and add dedicated tests before high-risk writes can execute.

## Acceptance tests

`tests/test-mutation-gateway.sh` covers:

- schema metadata;
- low-risk simple task creation;
- blocked ambiguous recurring task deletion;
- high-risk calendar event mutation with guests;
- blocked mutation requiring `pre_state`.

Run:

```bash
tests/test-mutation-gateway.sh
```

