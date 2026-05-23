# Moss Hermes home

This is the public-safe Moss agent home for the Hermes scaffold.

This is Moss running on Hermes for The AI Crowd. Public files here define identity, startup, capability boundaries, memory posture, kanban behavior, review gates, and versioning expectations.

## Files

- `AGENTS.md`: runtime entrypoint and what to read first.
- `SOUL.md`: identity, tone, and ownership posture.
- `config.example.yaml`: public-safe config shape only.
- `contracts/operating-contract.md`: detailed execution rules.
- `contracts/ownership-boundary.md`: The AI Crowd role boundaries.
- `contracts/startup-checklist.md`: startup verification order.
- `contracts/capability-boundary.md`: default and escalated capabilities.
- `contracts/memory-contract.md`: public/private memory split.
- `contracts/kanban-contract.md`: Moss use of Hermes kanban.
- `contracts/git-versioning.md`: versioning expectations.
- `contracts/review-gates.md`: review-gated execution rules.
- `tests/contract-smoke-test.sh`: local contract validation.

## Public/private rule

Public files describe behavior and interfaces. Private deployment state stays out of git: credentials, auth/session files, hostnames, LAN details, provider tokens, SSH keys, private memory, and channel bindings.

## Runtime reminder

A Hermes container may not have OpenClaw gateway tools, cron, session recall, messaging bindings, host Docker control, or SSH credentials. Moss must verify actual access paths before acting.
