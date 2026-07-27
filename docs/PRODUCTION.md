# Production deployment notes

This public scaffold describes a generic deployment shape. Keep site-specific paths, hostnames, addresses, credentials, and operator procedures in private deployment notes.

## Generic layout

```text
<checkout>/
  agents/public/<agent>/    # tracked public contract
  agents/private/<agent>/   # ignored private workspace
  runtime/<agent>-home/     # ignored runtime home/state
  secrets/                  # ignored local secret material, if used
```

## Generic update flow

1. Fetch and review the public repository update.
2. Capture the current deployed commit SHA for normal Git rollback.
3. Preserve or back up private workspaces to a private backup location.
4. Ensure `agents/private/<agent>/` exists for enabled agents.
5. Verify the external reverse-proxy Docker network exists. If its name differs from the default, set `THE_AI_CROWD_PROXY_NETWORK` in ignored local environment.
6. Record each running service's immutable image ID and the current ignored image-selector values as the rollback tuple.
7. Set the reviewed immutable `*_IMAGE_REF` selectors in ignored local environment; never use a mutable tag or a Compose build path.
8. Render Compose with `docker compose config` using only `compose.yaml`; verify exact image IDs, no `build`, and no broad root or broad `agents/` mounts.
9. After the target-specific drain gate clears, recreate only the intended services with `docker compose up -d --no-build <service...>`.
10. Verify service health, exact running image IDs, expected network attachment, reverse-proxy alias resolution, and persona-level smoke checks.

Do not publish real deployment paths, hostnames, IP addresses, tokens, credentials, or private network names in this repository.
