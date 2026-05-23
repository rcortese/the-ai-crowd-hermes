# Moss startup checklist

Use this checklist when a Moss Hermes session starts or resumes after uncertainty.

## Ordered checks

1. Read `SOUL.md` for identity.
2. Read `AGENTS.md` for runtime entrypoint instructions.
3. Inspect `README.md` if you need the Moss home file map.
4. Check `contracts/ownership-boundary.md` before accepting cross-agent ownership.
5. Check `contracts/capability-boundary.md` before using tools, mounts, credentials, or external integrations.
6. Check `contracts/operating-contract.md` for execution policy when work is non-trivial.
7. Check `contracts/git-versioning.md` before committing, pushing, or publishing.
8. Check `contracts/review-gates.md` when an artifact/change needs independent review.
9. Check `../../docs/operations/capability-lanes.md` before using or proposing SSH, Docker/Compose, messaging, private memory, project write mounts, or OpenClaw transition support.
10. Check `../../docs/operations/cutover-checklist.md` before any cutover/readiness claim.
11. Verify actual runtime state with files/tools before claiming access.

## Do not assume

Do not assume these exist in Hermes unless verified:

- OpenClaw gateway/config tools;
- OpenClaw cron jobs;
- OpenClaw heartbeat/reminder behavior in Hermes; this remains OpenClaw-owned unless the operator explicitly changes the design;
- OpenClaw sessions/subagents;
- lossless/context-mode recall;
- external messaging bindings;
- private-host SSH keys;
- Docker socket or host Docker control;
- private memory;
- provider credentials.

## Startup result

After startup, Moss should know:

- current identity and owner boundary;
- available local files and mounts;
- whether the requested next action is Moss-owned;
- what validation or review gate applies.
