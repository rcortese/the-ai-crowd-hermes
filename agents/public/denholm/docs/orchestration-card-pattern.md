# Orchestration Card Pattern

Status: active pattern
Owner: Denholm — Dono do Produto
Created: 2026-05-12

## Purpose

Use an Orchestration Card when Denholm coordinates a specialist through a bounded phase of implementation or analysis.

The pattern keeps Denholm as product/orchestration owner while letting the specialist execute without receiving a heavy project-management packet.

It is deliberately lightweight: one card per phase, one concise completion response back.

## When to use

Use this pattern when all of these are true:

- Rodolfo approved or requested Denholm to coordinate work across specialists.
- The work benefits from phase-by-phase control.
- The receiving specialist needs enough context to act without re-deciding the product direction.
- Ownership boundaries matter.
- The phase may produce file changes, commits, validation, operational risk, or future handoffs.

Typical examples:

- Denholm asks Moss to implement a product contract technically.
- Denholm asks Moss for a bounded technical discovery before a Richmond-owned ArchiveOps phase.
- Denholm asks a specialist to execute one phase while Denholm remains responsible for product framing and next-step selection.

## When not to use

Do not use an Orchestration Card for:

- a simple question;
- pure status recap;
- a one-line specialist consultation;
- an already-owned phase where the specialist can continue directly;
- review gates, which use the independent review-gate contract instead;
- emergency containment, where safety instructions should be direct and minimal.

## RPC hygiene

A new Orchestration Card is sent with one bounded `persona_rpc(target=<specialist>, question=<card>)` call to the owning specialist.

Do not route the card through `sessions_spawn`, `sessions_send`, `main`, `dashboard`, direct-chat, group, Kanban, shared files, a broker, or any active Rodolfo conversation. The RPC request is self-contained and the target's private session history is not an input.

When continuity matters, state it explicitly in the card without selecting or reusing a session:

```text
Contexto a preservar: <specific context>
Contexto a ignorar: <old/incidental context to disregard>
```

Default path:

1. Select the accountable specialist target.
2. Put the complete Orchestration Card in the required `question` field of `persona_rpc`; `target` and `question` are the only accepted arguments.
3. Treat the returned receipt with `status: ok | error` as the only result for that call.
4. If RPC fails, report the precise capability failure and stop; do not route the work through another channel.

The card itself should carry the required context; it should not depend on old session history.

## Card template

```text
Fase: <number/name>
Objetivo: <one sentence>
Escopo permitido: <what the specialist may inspect/change>
Não fazer: <explicit non-goals and forbidden side effects>
Pontos críticos de review: <2-5 items that deserve extra care>
Critério de aceite: <observable proof of completion>
Pare e reporte se: <blockers or risk thresholds>
Resposta esperada: <required completion shape>
```

Keep each field short. If the card needs long background, link the source artifact instead of pasting everything.

## Completion response template

The specialist should answer Denholm in this shape:

```text
STATUS: completed | blocked | needs_decision
PHASE: <number/name>
CHANGES: <files/areas changed or inspected>
COMMITS: <commit ids, push state, or none>
VALIDATION: <checks/reviews/proof>
RISKS: <residual risks or none>
LEARNINGS: <what should adjust the next phase>
NEXT_RECOMMENDATION: <continue / pause / change plan / ask Rodolfo>
```

Denholm then decides the next phase, records the learning if useful, and only escalates to Rodolfo when the stop condition requires it.

## Ownership rules

- Denholm owns product intent, sequencing, and whether the next phase should proceed.
- The receiving specialist owns execution quality inside the phase.
- A card is not a full ownership transfer unless it explicitly says so.
- For ArchiveOps, Richmond remains ArchiveOps steward; Moss may provide technical support only inside the authorized phase.
- The Elders consume prepared packets and should not be used as a live fallback for raw ArchiveOps rereads.

## Incident and noise handling

If another session or agent sends a panic/containment message during a card-driven run:

1. If Rodolfo directly instructs stop/pause, stop.
2. If the message is from another agent/session, classify whether it identifies a real safety risk or is incident noise.
3. Continue only work that is still within the current card and its stop conditions.
4. Pause before operational side effects that the card did not clearly authorize.
5. Record the decision in the completion response if it affected execution.

## Good card example

```text
Sessão: nova sessão limpa
Fase: 2 — Prepared index data model
Objetivo: Define the minimal manifest/index model that lets Richmond prepare once and The Elders answer quickly.
Escopo permitido: Edit docs, schemas, examples, tests, and validation scripts in Richmond/The Elders workspaces.
Não fazer: Do not read raw archive material. Do not change runtime config. Do not start Phase 3.
Pontos críticos de review: provenance, schema drift Richmond ↔ Elders, incremental reuse, missing-coverage support.
Critério de aceite: Contract docs and deterministic validation pass; commits are scoped.
Pare e reporte se: Raw archive access, runtime/config changes, or product-scope expansion appears necessary.
Resposta esperada: STATUS/PHASE/CHANGES/COMMITS/VALIDATION/RISKS/LEARNINGS/NEXT_RECOMMENDATION.
```

## Anti-patterns

- Sending a multi-page project brief when a short phase card would work.
- Sending a new task into a dirty old specialist session, especially one carrying incident/debug/product context from a different run.
- Sending A2A work into `main`, `dashboard`, direct-chat, group, or any active Rodolfo conversation.
- Reusing a session without naming what context should be preserved and what should be ignored.
- Asking Rodolfo to create/open a clean Moss execution session instead of using Denholm's session-spawn capability.
- Letting Moss infer product decisions from implementation details.
- Treating Denholm as a generic dispatcher instead of product owner.
- Bouncing a request between agents without a clear owner.
- Advancing phases automatically after a completion response when the learning changed risk or scope.
