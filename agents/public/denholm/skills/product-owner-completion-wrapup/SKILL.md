---
name: product-owner-completion-wrapup
description: Use when Denholm starts or finishes substantial Denholm-owned product work, multi-session product orchestration, important product artifacts, approved specialist handoffs, or any task where Rodolfo asked to be notified on Telegram when Denholm is done. Produces a concise product-owner completion/blocked notice via Denholm's Telegram account, while preserving Denholm's non-operator boundaries.
---

# Product Owner Completion Wrapup

## Purpose

Wrap substantial Denholm product-owner work with a reliable completion contract: define what done means, keep a product evidence note, produce or update the durable artifact when useful, and notify Rodolfo through Denholm's Telegram account when the work is completed, blocked, or failed.

This is Denholm's product-owner equivalent of a long-task wrapup. It is not a technical execution skill and must not turn Denholm into Moss.

## Activation

Use this skill when any condition is true:

- Denholm is about to do product work likely to take more than a few minutes.
- The work uses subagents, specialist handoffs, or multiple review/evidence passes.
- The work creates or changes an important Denholm product artifact, behavior contract, roadmap, decision packet, or handoff card.
- Rodolfo asks Denholm to notify him when finished.
- A specialist implementation was approved and Denholm needs to close the product loop after receiving evidence.
- The work has a meaningful terminal state Rodolfo should not have to poll for.

Do not use this for short chat answers, small clarifications, routine shadow findings, empty digests, or technical progress logs.

## Completion contract

At the start of substantial work, define:

- Objective: product outcome and what "finished" means.
- Authorization status: proposed, approved by Rodolfo, blocked pending approval, or evidence-only.
- Expected artifacts: decision packet, handoff card, product doc, review note, or none.
- Evidence needed: files, reviewer verdict, specialist completion, validation output, or explicit blocker.
- Telegram notice: Denholm completion/blocked notice to Rodolfo.
- Non-goals: technical execution, runtime mutation, provider data mutation, or broad proactive contact.

## Workflow

1. Use Denholm's normal product-owner chain first:
   - `planner-before-tools` for order, side effects, and gates.
   - `product-decision-synthesis` for product decisions.
   - `agent-handoff-spec` for specialist handoffs.
   - `boundary-routing-check` when ownership is ambiguous.
   - `fresh-review-loop` for important product artifacts before treating them as settled.
2. Keep a lightweight evidence note while working:
   - product problem;
   - decision or recommendation;
   - authorization evidence;
   - artifacts touched;
   - specialists consulted or handed off;
   - validation/review evidence;
   - blockers and next decision needed.
3. If the work created an important durable artifact, update the artifact in Denholm's workspace and cite it in the completion notice.
4. Send one concise Telegram notice through Denholm's configured Telegram account when the work reaches a terminal state.
5. Reply in the current session with the same status, evidence, and artifact path.

## Telegram destination

Use only Denholm's configured Telegram product-owner path:

- channel: `telegram`
- accountId: `denholm`
- target/chatId: not migrated in Hermes

If this path is unavailable or the `message` tool is unavailable, do not silently substitute Moss, Jen, Roy, WhatsApp, email, or another channel. State that Denholm notification is blocked and include the reason in the current session.

## Message shape

Keep Telegram short and phone-readable:

```text
Denholm — conclusão de produto

Status: completed | completed_with_warnings | blocked | failed
Trabalho: <short product-thread name>
Resultado: <1-3 short bullets or one short paragraph>
Evidência: <artifact path, reviewer verdict, or specialist completion>
Próximo passo: <none / Rodolfo decision / specialist owner>
```

For blocked/failed work, name the smallest unblocking decision or missing evidence.

Do not include secrets, raw logs, private message bodies, credentials, long diffs, or sensitive provider content in Telegram. Put details in a local Markdown artifact and cite its path.

## Boundaries

Denholm may send only this completion/blocked notice through the explicitly configured Denholm Telegram account.

This skill does not authorize Denholm to:

- mutate OpenClaw runtime/config, credentials, provider state, Todoist, Calendar, email, WhatsApp, or GitHub;
- send routine logs, technical progress spam, empty digests, or speculative shadow commentary;
- speak through Moss's Telegram identity;
- expand autonomy, cadence, channel reach, routing rules, role boundaries, external-write authority, source-of-truth ownership, or sensitive-data posture without Rodolfo authorization.

If completion evidence reveals a new behavior-changing product decision, stop and ask Rodolfo or create a Denholm decision proposal instead of silently implementing it.

## Done criteria

The wrapup is complete only when:

- the terminal status is explicit;
- the durable artifact/report path is cited when one exists;
- validation or review evidence is named when applicable;
- Telegram was sent through `accountId=denholm`, or the exact notification blocker is stated;
- the current session receives the concise final summary;
- forbidden technical/operator side effects were not performed by Denholm.
