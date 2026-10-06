# Moss capability lanes

Status: public scaffold contract
Owner: Moss

This runbook converts the migration gap findings into explicit capability lanes. A lane documents the safe path from no authority to reviewed private authority. It does not grant authority by itself.

## Common lane rules

Every high-impact lane requires:

1. public contract or runbook;
2. private overlay or private config when secrets/access are needed;
3. wrapper or narrow tool entrypoint;
4. dry-run or read-only proof before mutation;
5. review gate on the current artifact/evidence;
6. rollback/disable path;
7. public-safe evidence refs instead of private raw logs.

Do not enable a lane by broadly mounting host filesystems, Docker socket, credentials, channel tokens, or private memory.

## Lane: external messaging

Purpose: restore completion notices and operator-visible updates without granting broad chat authority.

Default status: disabled.

Allowed first implementation:

- dry-run wrapper only;
- direct direct messaging completion-notice contract only;
- public-safe recipient placeholders or `private-ref:*` handles;
- no group-chat behavior;
- no raw private logs or secrets in messages.

Before live delivery:

- private channel credential and recipient policy exist;
- disable switch exists;
- dry-run evidence is reviewed;
- one authorized direct-message smoke succeeds;
- logs show only sanitized message summaries.

## Lane: private-host SSH

Purpose: restore Moss read-only and later mutation-capable private infrastructure operations.

Default status: disabled.

Allowed first implementation:

- read-only preflight wrapper;
- no private key material in public repo;
- allowed host/user aliases defined in private policy;
- dry-run proof in public validation;
- live SSH only with private overlay and explicit environment gate.

Before mutation-capable SSH:

- read-only smoke to every required host succeeds;
- wrapper denies out-of-scope hosts/commands;
- mutation command classes are enumerated;
- rollback expectations are documented;
- review gate approves the specific wrapper behavior.

## Lane: Docker/Compose host control

Purpose: restore container maintenance without raw Docker socket authority.

Default status: disabled.

Preferred access model:

- SSH-mediated Compose wrappers or remote Docker context;
- no `/var/run/docker.sock` mount unless separately justified and reviewed.

Allowed first implementation:

- repo-local compose config validation;
- read-only status/log command shape;
- dry-run wrapper evidence;
- explicit service/stack scope in private policy.

Before mutation:

- render compose config before action;
- show affected services;
- require operator/task confirmation for pull/recreate/restart;
- require separate explicit confirmation for destructive operations;
- record rollback notes.

## Lane: project file mounts

Purpose: allow Moss to inspect or modify explicitly selected project repositories.

Default status: private-config-required.

Rules:

- each project mount is named and scoped;
- default example project mount remains read-only;
- write mounts require a private deployment note and review gate;
- every modified project follows scoped Git status/diff/test/commit rules.

## Lane: OpenClaw runtime transition support

Purpose: let Hermes Moss support OpenClaw during transition without pretending Hermes has native OpenClaw tools.

Default status: fallback-to-OpenClaw unless a reviewed wrapper exists.

Task classes:

| Task class | Default route |
|---|---|
| OpenClaw config inspection | OpenClaw Moss or reviewed admin wrapper |
| OpenClaw restart/reload | OpenClaw Moss or explicit operator-approved wrapper |
| OpenClaw cron/job inventory | OpenClaw Moss |
| Heartbeat behavior/reminders | OpenClaw only; not migrated to Hermes |
| Session/subagent diagnostics | OpenClaw Moss unless Hermes replacement exists |
| Lossless/context recall health | OpenClaw Moss unless Hermes replacement exists |

Hermes docs and prompts must not claim these capabilities are available until a concrete access path is verified.

## Lane: private memory

Purpose: preserve Moss continuity while avoiding bulk-copy or public leakage.

Default status: private-curated-import-required.

Rules:

- use an import manifest;
- classify each source;
- import Moss-owned curated summaries only;
- exclude credentials, auth state, raw sessions, caches, dumps, logs, and other agents' private state;
- public docs use `private-ref:*`, never raw private content.

## Lane readiness template

```text
lane: <name>
status: disabled|dry-run-ready|read-only-ready|mutation-ready|blocked
public_contract: <path>
private_policy_ref: <private-ref or blocked>
wrapper: <path or blocked>
dry_run_evidence: <ref or blocked>
read_only_evidence: <ref or blocked>
mutation_policy: <ref or not-applicable>
review_gate: <id or blocked>
disable_or_rollback: <ref or blocked>
notes: <public-safe notes>
```
