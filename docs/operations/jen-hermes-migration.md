# Jen migration — generic planning template

This is an example sequence, not an incident record or evidence of completed migration. Actual authentication, job IDs, recipients, image identity, commands and results belong to private deployment records.

## Boundaries

- Jen owns productivity, tasks and Calendar behavior; Moss owns authorized technical runtime work.
- Do not import bulk private memory or sessions, copy another persona's credentials, or publish runtime state.
- Review each stage independently against exact source bytes. Source validation is distinct from runtime authorization.
- Do not perform external writes, install images or switch channels merely because this template describes those stages.

## Suggested stages

1. **Source scaffold.** Review Jen identity and ownership. Use explicit compatible image/runtime/workspace variables from the public Compose example, whose mount targets are `/contracts`, `/runtime` and `/workspace`. Keep external channels disabled.
2. **Calendar tooling.** Select and verify an appropriate upstream gogcli release in private build tooling. Keep keyring and account state private. Check that missing auth fails closed; an installed binary is not authenticated access.
3. **Read-only Calendar wrappers.** Test synthetic health, events and free/busy responses. Require explicit timezone-aware ranges and handle unavailable/auth-failure outcomes. Enable writes only after mutation and idempotency gates.
4. **Todoist integration.** Configure official provider access only in Jen's private runtime. A headless OAuth timeout is a possible failure case, not permission to reuse a different persona's token. Tool discovery does not authorize raw write tools.
5. **Mutation safety.** Validate write boundaries, retries and idempotency with fake transports first. Any later real smoke write must be explicitly authorized, reversible, read back and cleaned up with private evidence.
6. **Scheduled jobs.** Migrate only individually approved read-only jobs; do not bulk-import scheduling or heartbeat behavior. Keep delivery local until independently approved. Store job identifiers and actual schedules privately and prove pause/remove behavior.
7. **Channel cutover.** Use configured private credentials and recipient allowlists. Prevent concurrent polling consumers, preserve unaffected accounts, prove inbound/outbound behavior only under explicit authorization, and prepare rollback before switching.

## Evidence and rollback

Record immutable source/image identity, private backup and restore rehearsal, runtime readiness, auth posture, review verdicts and operator approval. Use private references in public summaries, not account handles, numeric chat IDs, token hashes, job IDs or session IDs. Rollback restores only the intended service/channel from its reviewed private preimage; it never broadens authority or changes other personas.

The public offline suite exercises source/fixture behavior. It does not report any live Jen gateway, credentials, channel delivery or scheduled job as enabled.