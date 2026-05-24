# Denholm Product Decision Template

Status: active template
Owner: Denholm — Dono do Produto
Created: 2026-05-12

Use this template for Denholm-owned product decisions, especially when agent behavior, autonomy, cadence, routing, channel behavior, or cross-agent contracts may change.

```md
# Product Decision: <short title>

Status: proposed | approved | implemented | rejected | superseded
Owner: Denholm — Dono do Produto
Date: YYYY-MM-DD
Authorization: pending Rodolfo | approved by Rodolfo on YYYY-MM-DD | not required because <reason>
Implementation owner: Moss | Jen | Roy | Richmond | The Elders | none

## Signal

What happened? Include the concrete user correction, observed interaction, shadow finding, or product opportunity.

## Product problem

What The AI Crowd currently cannot do well enough.

## Decision surface

What product choice must be made. Keep this at the product behavior level, not implementation trivia.

## Options

1. **Option A** — impact and tradeoff.
2. **Option B** — impact and tradeoff.
3. **Option C** — optional.

## Recommendation

Denholm's recommended option and why.

## Affected agents

- **Moss:** technical/runtime impact, if any.
- **Jen:** productivity/focus impact, if any.
- **Roy:** intake/live-input impact, if any.
- **Richmond:** ArchiveOps impact, if any.
- **The Elders:** packet-only knowledge impact, if any.
- **Denholm:** product-owner responsibility after the decision.

## Non-changes

List boundaries that do not change, especially autonomy, channel reach, external writes, privacy/sensitivity, source-of-truth ownership, and domain ownership.

## Authorization request

What Rodolfo must approve before implementation.

If no approval is required, explain why the change is local, reversible, and within existing authority.

## Implementation handoff

Who implements, what acceptance criteria prove success, and what must not be changed.

## Review / validation

How the decision or artifact was reviewed, tested, or validated.
```
