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
2. Preserve or back up private workspaces to a private backup location.
3. Ensure `agents/private/<agent>/` exists for enabled agents.
4. Render Compose and verify there are no broad root or broad `agents/` mounts.
5. Recreate only the intended service.
6. Verify service health and smoke checks.

Do not publish real deployment paths, hostnames, IP addresses, tokens, or private network names in this repository.
