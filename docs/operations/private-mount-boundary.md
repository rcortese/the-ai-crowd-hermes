# Private mount boundary

Status: public scaffold contract
Owner: Moss

Hermes uses public source mounts plus private overlays. This document closes the migration gap where ignored private files could accidentally become visible through a path that a tool treats as public-safe.

## Rule

In a public scaffold checkout, `/workspace/the-ai-crowd` may be treated as public source.

In a private deployment checkout, `/workspace/the-ai-crowd` is **not automatically public-safe** unless the deployment proves that ignored private/runtime paths are excluded from that mount.

## Risk pattern

The base Compose file mounts:

```text
./agents/moss:/opt/data
.:/workspace/the-ai-crowd:ro
```

If a private deployment stores ignored private files under `agents/moss/private/`, a repo-wide read-only source mount could make those files visible at:

```text
/workspace/the-ai-crowd/agents/moss/private/...
```

That is not a leak into public Git by itself, but it can become a private-data exposure inside the container if tools or scans assume `/workspace/the-ai-crowd` is public-safe.

## Accepted private deployment patterns

Choose one before private cutover.

### Preferred pattern: exclude private/runtime paths from public source mount

Use a private deployment layout or mount strategy where these paths are not present under the repo-wide read-only public-source mount:

- `agents/*/private/`
- `agents/*/.env`
- `agents/*/config.yaml`
- `agents/*/auth.json`
- `agents/*/auth.lock`
- `agents/*/.anthropic_oauth.json`
- `agents/*/sessions/`
- `agents/*/cache/`
- `agents/*/logs/`
- `agents/*/runtime/`
- private overlays, backups, dumps, and secrets

### Alternative pattern: declare source mount private-aware

If private deployment intentionally keeps the repo-wide mount, all tooling must treat `/workspace/the-ai-crowd` as private-aware, not public-safe. Public-release scans must run on the Git index and public checkout, not on private runtime mounts.

This alternative requires a private deployment note explaining:

- why the repo-wide mount remains necessary;
- what private paths are visible;
- which tools are allowed to scan/read the mount;
- how accidental export or publication is prevented.

## Validation expectation

A private deployment should include a sentinel test before cutover:

1. Place a private sentinel under the private state root.
2. Verify it is not reachable through the path used by public-source tooling.
3. If it is reachable, either change mounts or mark the mount as private-aware and block public-safe scan assumptions.

Public scaffold validation cannot create real private sentinels. It can only verify that this contract exists and that public examples do not mount private host paths, SSH material, Docker socket, auth files, or broad host filesystems.

## Public documentation rule

Public docs may mention placeholder paths such as `/srv/example/the-ai-crowd` or `private-ref:*`. They must not include real private deployment paths, hostnames, IPs, phone numbers, credentials, or SSH key names.
