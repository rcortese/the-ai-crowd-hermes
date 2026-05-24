# Subagent and Session Orchestration Contract

Status: proposed product/stewardship contract
Owner: Denholm — Dono do Produto
Created: 2026-05-18
Scope: product policy for delegated subagent/session work in The AI Crowd

## Product problem

Delegated work currently has a failure mode where the parent session waits, a child/subagent/reviewer is still running or has timed out, and Rodolfo has to alt-tab between sessions and ask "eai" to discover the real state.

That is a product failure, not merely a runtime inconvenience. The user-facing experience must not depend on Rodolfo tracking hidden child lifecycles or interpreting raw completion events.

## Product principle

Every delegated work item must have:

1. **Owner** — exactly one parent/session owner remains accountable to Rodolfo.
2. **Explicit lifecycle state** — the work is `active`, `waiting`, `blocked`, `completed`, `closed`, or explicitly `async`.
3. **SLA/status cadence** — silence has a limit; interactive work gets visible status before it becomes confusing.
4. **Terminal outcome** — every delegation ends as completed, blocked, closed, or deliberately async with a named follow-up path.
5. **Escalation** — lost, timed-out, stale, or contradictory child/reviewer state becomes a blocker or decision surface, not an indefinite wait.

## Immediate operating policy

This policy applies now as a stewardship contract for parent sessions, subagents, and reviewers. It does not require runtime implementation to be valid as product behavior.

### Parent responsibility

- The parent/session owner retains responsibility for the user-facing phase until explicitly handed off or closed.
- Delegating work to a subagent or reviewer does not transfer responsibility to that child.
- The parent must translate child/reviewer results into a user-facing completion, blocker, or next decision. Raw completion events are evidence, not the final answer.

### No indefinite waiting

For interactive work unless the parent explicitly marks the task `async`:

- After **5 minutes** without a useful child/reviewer result, the parent provides a short status update or records why no user-facing update is appropriate.
- After **15 minutes**, the parent escalates, closes, or marks the task blocked unless there is a clear, still-valid reason to continue waiting.
- A timed-out, lost, stale, or ambiguous child/reviewer result becomes a blocker or a fresh decision surface. It must not be treated as invisible background progress.

### Async exception

A task may be marked `async` only when the parent names:

- who owns the follow-up;
- what output is expected;
- when Rodolfo should expect another update or what event will trigger it;
- what counts as terminal closure.

`Async` is not permission to disappear. It is a named lifecycle state with a follow-up contract.

### Completion rewriting

When a subagent/reviewer completes, the parent rewrites the result for Rodolfo:

- what changed or was found;
- whether acceptance criteria were met;
- what remains risky or blocked;
- what the next action is;
- whether the delegated work is now closed.

The parent should not make Rodolfo inspect child sessions to understand the answer.

## Product policy vs runtime implementation

This document defines the desired product behavior and stewardship rules. It does **not** define or authorize runtime mechanics.

Product policy includes:

- lifecycle semantics;
- parent accountability;
- user-facing status cadence;
- blocker/escalation expectations;
- review-gate sequencing;
- reflection requirements.

Runtime implementation belongs to Moss and may include, after approval and review, changes to session APIs, status events, timeouts, dashboards, prompts, ledgers, or notification mechanics. Those details must not be inferred from this product contract alone.

## Phased implementation plan

### Phase 1 — Product/stewardship contract

Owner: Denholm.

Objective: establish the product rule that delegated work cannot become an invisible waiting state for Rodolfo.

Allowed work:

- write or update Denholm-owned product/stewardship docs;
- clarify policy for parent sessions, subagents, reviewers, lifecycle states, status cadence, escalation, and completion rewriting;
- keep the document English by default.

Non-goals:

- no runtime/config implementation;
- no cron, credential, provider, or external-service changes;
- no commits required by the contract itself.

Review gate: **Gate 1 — product/stewardship review**

Gate 1 checks whether the contract is clear, bounded, and product-owned. It should verify the acceptance criteria, ownership language, and separation from runtime implementation.

### Phase 2 — Operational/runtime-safety design and implementation handoff

Owner: Moss for operational/runtime design and execution after Rodolfo/Denholm approval; Denholm remains product owner for behavior and acceptance.

Objective: turn the product contract into safe operational behavior without breaking session routing, reviewer boundaries, or user-facing trust.

Allowed work after authorization:

- technical discovery of current session/subagent/reviewer lifecycle behavior;
- proposed runtime-safe design for status, timeout, completion rewriting, and blocker reporting;
- implementation plan, validation, rollback, and evidence gates;
- scoped runtime/config changes only after proper approval.

Non-goals:

- do not expand agent autonomy, channel reach, or external-write authority as a side effect;
- do not blur ownership agents with reviewer/subagent utility identities;
- do not make Rodolfo responsible for monitoring hidden runtime state.

Review gate: **Gate 2 — operational/runtime-safety review**

Gate 2 is more critical and requires more review energy than Gate 1. It must evaluate runtime safety, ownership/routing boundaries, timeout semantics, stale/late completion handling, rollback, and user-facing failure modes. Gate 2 should use stronger evidence than a document read alone: deterministic checks, transcript fixtures, implementation diff review, or an independent runtime-safety reviewer as appropriate.

## Reflection protocol after each phase

After each phase, the phase owner records a short reflection before proceeding:

1. **What did we learn?** Evidence, surprises, and contradictions.
2. **Did ownership stay clean?** Parent owner, child/reviewer role, and specialist boundaries.
3. **Did the user experience improve?** Specifically: would Rodolfo still need to alt-tab and ask "eai"?
4. **Did risk change?** New autonomy, cadence, routing, privacy, runtime, or external-write implications.
5. **Proceed, revise, or stop?** Name the next action and the owner.

Reflection is required even when the phase succeeds. A clean success should still produce closure and the next owner/action.

## Acceptance checklist

- Delegated work has owner, lifecycle state, status cadence, terminal outcome, and escalation.
- Interactive work has no indefinite waiting: status around 5 minutes, escalate/close/block around 15 minutes unless explicitly async.
- Parent sessions retain responsibility and rewrite child/reviewer results for Rodolfo.
- Product policy is separate from Moss-owned runtime implementation.
- The plan has exactly two review gates: Gate 1 product/stewardship, Gate 2 operational/runtime-safety.
- Gate 2 is explicitly treated as more critical and review-intensive.
- Each phase has a reflection step before proceeding.
