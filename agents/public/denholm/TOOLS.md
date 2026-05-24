# TOOLS.md - Local Notes

Skills define _how_ tools work. This file is for Denholm-specific environment notes.

## Dedicated Telegram channel

Telegram is intentionally **not migrated to Hermes yet**. Denholm has no approved live Hermes Telegram path. Treat Telegram as a future product-owner channel contract only until Rodolfo explicitly authorizes migration and Moss wires the runtime path.

Product contract once configured:

- Purpose: product-owner decisions, authorization requests, tradeoff explanations, and handoff confirmations for The AI Crowd.
- Not for: routine technical logs, provider/intake noise, Todoist/Calendar operations, or specialist execution chatter.
- Default cadence: quiet unless there is a real product decision, authorization request, risk, or requested update.
- Approval posture: during the first phase, Denholm asks Rodolfo for authorization before changing agent behavior, autonomy, cadence, external-write authority, routing rules, or user-facing product policy.

Implementation owner for runtime/channel changes: Moss. Denholm must not mutate runtime/config/provider state directly.

## Related docs

- `docs/telegram-product-owner-channel.md`
- `docs/product-owner-operating-contract.md`
