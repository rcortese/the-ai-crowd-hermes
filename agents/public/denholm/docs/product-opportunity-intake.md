# Product Opportunity Intake

Status: active
Owner: Denholm — Dono do Produto
Created: 2026-05-11
Updated: 2026-05-12

## Purpose

This is Denholm's intake surface for real-world moments that reveal how The AI Crowd should evolve as a product.

A product opportunity is not automatically an implementation request. It is a concrete signal that an agent, handoff, cadence, boundary, channel behavior, or user-facing behavior may need a product decision.

## Triggers

Treat a user remark as a Denholm product-opportunity input when it says or implies:

- “this is a good opportunity to evolve agent X”;
- a real message/event exposed a missing capability;
- an agent boundary is unclear;
- Moss is answering technically when the user is asking for product shaping;
- a flow should become more useful without increasing autonomy unsafely;
- Denholm should own a product decision, Telegram behavior, authorization posture, or cross-agent direction.

## Product-opportunity packet

For each high-signal opportunity, Denholm should capture:

1. **Observed real-world signal** — what happened, without copying unnecessary private content.
2. **Product gap** — what The AI Crowd cannot yet do well.
3. **Affected agent(s)** — e.g. Roy as intake owner, Jen as productivity consumer, Moss as technical implementer.
4. **Decision needed** — the product choice, not the implementation detail.
5. **Options** — 2-3 viable product behaviors.
6. **Recommendation** — Denholm's default when evidence is sufficient.
7. **Authorization needed** — what Rodolfo must approve before behavior changes.
8. **Non-changes** — autonomy, external writes, domain ownership, and privacy boundaries that remain unchanged.
9. **Implementation handoff** — which specialist should implement after approval.

## Required conclusion

Every product-opportunity packet must end with one of:

- proposed product decision awaiting Rodolfo authorization;
- approved implementation handoff;
- deliberate non-action;
- owner handoff;
- one blocking question.

Do not leave opportunities as passive observations.

## Current opportunity: Roy sensitive-intake evolution from accountant/IRPF WhatsApp

Observed signal: Rodolfo reported that a WhatsApp from his accountant about IRPF arrived and said it is a good opportunity to evolve Roy.

Product gap: Roy has WhatsApp intake plumbing and specific policy-driven flows, but Denholm did not yet own a product-level process for turning real sensitive-intake examples into Roy evolution decisions. Moss also initially answered as a technical capability check, which was the wrong layer.

Affected agents:

- Denholm — owns the product decision for how Roy should evolve.
- Roy — owns live-input triage/intake behavior.
- Jen — may consume downstream productivity/action context if the item implies a task, deadline, or commitment.
- Moss — implements technical/runtime changes after product approval.

Decision needed: define Roy's product behavior for “external message + sensitive financial/legal/fiscal topic + possible deadline/documents”.

Options:

1. **Signal-only** — Roy detects and says a sensitive item likely needs attention.
2. **Triage-and-summary** — Roy identifies sender/topic/deadline/documents/risk/next decision and asks before action.
3. **Operational flow** — Roy also prepares downstream tasks/handoffs automatically.

Decision update after Rodolfo correction: do not adopt a temporary signal-only or partial behavior. The complete product behavior is **Roy analyzes qualifying sensitive external messages and signals Jen by contract**. Roy does not ask whether to involve Jen when the contract matches; Denholm owns the Roy → Jen contract.

Recommendation: implement the complete Roy → Jen sensitive-intake flow described in `docs/roy-jen-sensitive-intake-contract.md`. It increases value without granting Roy outbound authority, task writes, provider mutation, or domain-specialist judgment.

Non-changes:

- Roy does not reply to the accountant.
- Roy does not interpret tax law or act as an accountant.
- Roy does not mutate WhatsApp/provider state.
- Roy does not create Todoist/Calendar items directly.
- Jen owns productivity integration and personal-execution routines after receiving Roy's signal.
- Moss owns implementation mechanics only.
- Denholm owns this product contract and future changes to this behavior.

Implementation handoff if Rodolfo approves: Moss should implement a reviewed Roy → Jen sensitive-intake contract and tests in `roy-workspace` and Jen's relevant routine surface, preserving no-outbound/no-provider-mutation boundaries.
