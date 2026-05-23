# Rollback template

## Fast rollback: remove private route

Use this if the Hermes dashboard route is unsafe or broken.

1. In the private reverse-proxy config, remove the virtual host / route that points to `hermes:9119`.
2. Validate the reverse-proxy config.
3. Reload the reverse proxy.
4. Confirm the route is no longer reachable from unintended clients.

Example shape, adapt to the private deployment:

```bash
cd <private-proxy-config-root>
<proxy-validate-command>
<proxy-reload-command>
```

## Stop Hermes only

```bash
cd <deployment-checkout>
docker compose stop moss
```

## Full stack removal without deleting data

```bash
cd <deployment-checkout>
docker compose down
```

This leaves agent homes and repository files in place.

## Revert repository state

Before any hard reset, preserve local diffs if present:

```bash
cd <deployment-checkout>
git status --short
git diff > <private-secrets-or-backups-dir>/pre-reset-$(date +%Y%m%d%H%M%S).patch
```

Then revert to the pushed production reference:

```bash
git fetch origin
git reset --hard origin/main
docker compose up -d --build moss
```

Only use `git reset --hard` on the production checkout after confirming there are no local uncommitted production edits that need preserving.

## Data deletion

Do not delete the deployment directory as a rollback step unless the operator explicitly authorizes data destruction. If cleanup is needed, move the directory to a dated backup/trash path first.
