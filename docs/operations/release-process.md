# Release process

Status: Public contract
Owner: Moss

This process defines the minimum safe path for releasing Hermes Moss changes. It is a contract for public scaffold changes and a template for private deployment releases.

## Release sequence

1. Start from a clean working tree.
2. Confirm branch and upstream:
   ```bash
   git status --short --branch
   git log --oneline -5
   ```
3. Make scoped changes only.
4. Run public validation:
   ```bash
   ./tests/run-all.sh
   ```
5. Run authorized runtime smoke only when Docker access is allowed:
   ```bash
   ./tests/smoke-deploy.sh
   ```
6. Prepare a review package with:
   - user request or release objective;
   - changed artifacts;
   - validation output;
   - rollback procedure;
   - private-state impact;
   - deployment impact.
7. Obtain review-gate approval for the current artifact version.
8. Apply fixes and rerun validation if review requires changes.
9. Commit scoped public changes.
10. Inspect outgoing range:
    ```bash
    git log --oneline origin/main..HEAD
    git diff --stat origin/main..HEAD
    ```
11. Push to `origin/main` only when upstream is not behind/divergent and the scope is correct.
12. Record release evidence in private deployment notes before live routing/deploy changes.
13. Fill `docs/operations/cutover-checklist.md` evidence refs before any `production-live` claim.

## Human confirmation gates

Ask the operator before:

- changing live reverse-proxy routes;
- enabling external message delivery;
- mounting SSH keys, Docker socket, or provider credentials;
- modifying production data or live agent homes destructively;
- force-pushing or rewriting shared history;
- declaring OpenClaw fallback retired;
- moving heartbeat/reminder ownership out of OpenClaw.

## Rollback note template

Every production-impacting release should record:

```text
release: <short title>
public_commit: <sha>
base_image: <digest>
private_state_ref: private-ref:<id or blocked>
validation: <command/result>
smoke: <command/result or blocked reason>
rollback: file:docs/ROLLBACK.md + private-ref:<deployment rollback note>
openclaw_fallback: available|not-available + reason
```

## Release status meanings

- `public-scaffold-ready`: public repo validated and pushed; no live deployment change.
- `private-deploy-ready`: private overrides and backups prepared; no route change yet.
- `production-live`: live route/deployment changed and smoke-tested.
- `blocked`: missing confirmation, validation, backup, or credential strategy.

The public scaffold may reach `public-scaffold-ready`; it must not claim `production-live` without private deploy evidence and explicit operator approval.
