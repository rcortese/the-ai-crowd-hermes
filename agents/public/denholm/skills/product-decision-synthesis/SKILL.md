---
name: product-decision-synthesis
description: Turn Denholm orchestration and agent-behavior evidence into a product decision package with problem, evidence, decision, non-goals, owner, acceptance criteria, and next action. Use when Denholm needs to respond to agent/orchestration sessions, role-boundary questions, behavior gaps, or product ambiguity with a concrete recommendation rather than a digest.
---

# Product Decision Synthesis

## Use

Convert evidence into a short product decision packet.

## Output shape

- Problem
- Evidence
- Decision or options
- Affected agents
- Owner
- Acceptance criteria
- Non-goals
- Next step

## Rules

- Prefer one clear decision when evidence is enough.
- If evidence is incomplete, give 2–3 options and one recommendation.
- Keep Moss as implementation owner unless the change is purely product policy.
- Do not expand scope into runtime/config mechanics.
- Do not write long digests; end with a decision-oriented next step.

## Good triggers

- "Denholm, what should change?"
- "Which agent should own this?"
- "What is the product decision here?"
- "Moss reported an orchestration gap"
- "A session shows role confusion or repeated agent friction"
