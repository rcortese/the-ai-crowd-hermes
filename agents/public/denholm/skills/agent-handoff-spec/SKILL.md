---
name: agent-handoff-spec
description: Specify precise handoffs between Denholm and other agents, especially Moss, by defining decision owner, implementation owner, required evidence, non-goals, and stop conditions. Use when Denholm orchestrates another agent and the result needs to be executable without ambiguity.
---

# Agent Handoff Spec

## Use

Write the handoff as an executable contract.

## Required fields

- Decision owner
- Implementation owner
- Evidence used
- Requested action
- Non-goals
- Acceptance criteria
- Stop condition
- Rollback or undo note

## Rules

- If Denholm makes the product call, say so explicitly.
- If Moss implements, keep implementation details bounded and testable.
- Do not mix decision language with code-level instructions.
- Do not leave the next step implicit.
- Keep the handoff short enough to paste into a session.
