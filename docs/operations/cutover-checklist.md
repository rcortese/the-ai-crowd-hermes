# Moss cutover checklist

Status: public scaffold contract
Owner: Moss

This checklist prevents accidental `production-live` claims while Moss-on-Hermes is still closing private capability and continuity gaps.

## Status states

- `not-production-live`: default. Public scaffold may be valid, but private deployment evidence is incomplete.
- `public-scaffold-ready`: public tests pass and public docs/contracts are ready. No live cutover implied.
- `private-smoke-ready`: private deployment smoke, private backups, and rollback notes exist. No live route change implied.
- `production-live`: live route/deployment changed, smoke-tested, rollback-ready, and explicitly approved by the operator.
- `blocked`: one or more required evidence refs are missing.

## Required evidence before `production-live`

Record every item before live cutover language is allowed:

| Evidence | Required ref | Status |
|---|---|---|
| Public commit | `public_commit:<sha>` | blocked until recorded |
| Public validation | `tests/run-all.sh:<result-ref>` | blocked until recorded |
| Private smoke deploy | `tests/smoke-deploy.sh:<private-result-ref>` | blocked until authorized and recorded |
| Image digest | `image_digest:<sha256>` | blocked until recorded |
| Private deployment note | `private-ref:deployment-note` | blocked until recorded |
| Private state backup | `private-ref:backup` | blocked until recorded |
| Restore rehearsal | `private-ref:restore-rehearsal` | blocked until recorded |
| Rollback procedure/ref | `private-ref:rollback` plus `docs/ROLLBACK.md` | blocked until recorded |
| OpenClaw fallback status | `openclaw_fallback:available|not_available + reason` | blocked until recorded |
| Review gate approvals | `review-gate:<ids>` | blocked until recorded |
| Operator approval | `operator-approval:<id>` | blocked until the operator approves |

## Hard blocks

Do not mark Moss-on-Hermes as `production-live` when any of these is true:

- OpenClaw fallback status is unknown or unavailable without an explicit accepted reason.
- Private smoke deploy was not run or was not authorized.
- Backup and restore rehearsal evidence is missing.
- SSH, Docker/Compose, external messaging, provider credentials, project write mounts, or private reverse proxy were added without a review gate.
- A dashboard route using `--insecure` is exposed through host ports or public reverse proxy.
- Private OpenClaw memory was bulk-copied rather than curated.
- A public tracked file contains real private hostnames, IPs, paths, phone numbers, tokens, credentials, or private deployment notes.

## Cutover record template

```text
status: not-production-live|public-scaffold-ready|private-smoke-ready|production-live|blocked
public_commit: <sha or blocked>
public_validation: <result ref or blocked>
private_smoke: <private ref or blocked>
image_digest: <digest or blocked>
private_deployment_note: <private ref or blocked>
backup_ref: <private ref or blocked>
restore_rehearsal_ref: <private ref or blocked>
rollback_ref: <private ref or blocked>
openclaw_fallback: available|not_available + reason
review_gates: <ids or blocked>
operator_approval: <id or blocked>
notes: <public-safe notes only>
```

## Operator rule

Review approval is necessary but not sufficient for live cutover. `production-live` requires explicit the operator approval after the evidence refs above are available.
