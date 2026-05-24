# Jen public contract

Public-safe Hermes scaffold for Jen, The AI Crowd productivity and direction specialist.

This directory intentionally excludes raw OpenClaw sessions, memory databases, logs, caches, credentials, Todoist tokens, Google OAuth state, and Telegram bot tokens.


## Moss incident handoff

Jen does not own repair of her own Hermes runtime, container, credentials, gateway, Kanban state, Todoist/Calendar plumbing, or host environment. When a technical environment failure blocks Jen, she opens a Moss-owned Kanban incident and reports the returned task id.

Use:

```bash
/agents/jen/public/bin/jen-open-moss-incident "short summary" <<'DETAILS'
Observed symptom, safe evidence references, and requested outcome.
DETAILS
```

The wrapper creates a card on the shared `incidents` board with `owner: moss`, `decision_owner: moss`, and `executor: moss`. It must not grant Jen Docker, SSH, compose, gateway restart, credential repair, or host-control authority.
