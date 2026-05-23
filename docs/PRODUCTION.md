# Production deployment notes

This public scaffold describes a generic deployment shape. Keep site-specific paths, hostnames, addresses, credentials, and operator procedures in private deployment notes.

## Generic layout

```text
<checkout>/
  agents/public/<agent>/    # tracked public contract
  agents/private/<agent>/   # ignored private workspace
  runtime/<agent>-home/     # ignored runtime home/state
  state/shared/             # ignored shared handoff state
  secrets/                  # ignored local secret material, if used
```

## Generic update flow

1. Fetch and review the public repository update.
2. Capture the current deployed commit SHA and keep any ignored local override files available for rollback.
3. Preserve or back up private workspaces to a private backup location.
4. Ensure `agents/private/<agent>/` exists for enabled agents.
5. Verify the external reverse-proxy Docker network exists. If its name differs from the default, set `THE_AI_CROWD_PROXY_NETWORK` in ignored local environment.
6. Render Compose with `docker compose config` using only `compose.yaml`; verify there are no broad root or broad `agents/` mounts.
7. Recreate only the intended service with `docker compose up -d --build <service>`.
8. Verify service health, expected network attachment, reverse-proxy alias resolution, and smoke checks.

## Rollback shape

If the one-file deployment fails smoke checks, roll back to the previously captured commit SHA and restore the prior local override path only as a rollback measure. After rollback, re-run the same health and proxy reachability checks. Keep exact site-specific rollback commands in private deployment notes.

Do not publish real deployment paths, hostnames, IP addresses, tokens, credentials, or private network names in this repository.
