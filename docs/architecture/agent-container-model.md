# Agent container model

Hermes agents run as separate containers with separate runtime homes, public contracts, private workspaces, images, mounts, and capability boundaries.

## Runtime units

Each agent has:

- a Docker service;
- an image or Dockerfile;
- a public contract mounted at `/agents/<agent>/public`;
- a private workspace mounted at `/agents/<agent>/private`;
- a runtime home mounted at `/opt/data`;
- optional shared handoff material;
- a tool/capability manifest describing intended powers.

## Current services

| Agent | Service | Default status | Intent |
|---|---|---:|---|
| Moss | `moss` | enabled | technical operations and migration work |
| Richmond | `richmond` | profile-gated | ArchiveOps stewardship, later validation |
| The Elders | `the-elders` | profile-gated | packet-only read-oriented answers |

## Public contract

Tracked public-safe agent material lives under:

```text
agents/public/<agent>/
```

Inside the container it is mounted read-only at:

```text
/agents/<agent>/public
```

## Private workspace

Ignored private operational workspace material lives under:

```text
agents/private/<agent>/
```

Inside the container it is mounted read-write at:

```text
/agents/<agent>/private
```

The private workspace is for curated private operational material. Runtime caches, generated state, sessions, and tool noise should prefer `/opt/data` unless intentionally curated into the private workspace.

## Agent runtime home

The runtime home is writable high-churn state mounted at `/opt/data`. Services run as the deployment checkout UID/GID by default so files written through bind mounts remain editable by the host operator.

## Shared handoff mount

`state/shared/` is for explicit handoff artifacts that are safe for the configured agents. It is not a secret store and not a replacement for private state repositories.

## High-impact access

Host control is not a default property of an agent container. SSH keys, Docker socket access, host paths, provider credentials, and external channels require reviewed private overlays and capability contracts.
