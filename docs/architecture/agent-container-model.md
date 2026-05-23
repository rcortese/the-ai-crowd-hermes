# Agent container model

Hermes agents run as separate containers with separate homes, images, mounts, and capability boundaries.

## Runtime units

Each agent has:

- a Docker service;
- an image or Dockerfile;
- an agent home mounted at `/opt/data`;
- optional shared handoff material;
- optional private mounts added by deployment overlays;
- a tool/capability manifest describing intended powers.

## Current services

| Agent | Service | Default status | Intent |
|---|---|---:|---|
| Moss | `moss` | enabled | technical operations and migration work |
| Richmond | `richmond` | profile-gated | ArchiveOps stewardship, later validation |
| The Elders | `the-elders` | profile-gated | packet-only read-oriented answers |

## Agent home

The agent home is writable runtime state. In this scaffold it is represented by `agents/<agent>/`, mounted into the container as `/opt/data`. Services run as the deployment checkout UID/GID by default so files written through bind mounts remain editable by the host operator.

Public homes may contain templates and contracts. Production homes may contain private config and state that must remain ignored.

## Shared handoff mount

`shared/` is for explicit handoff artifacts that are safe for the configured agents. It is not a secret store and not a replacement for private state repositories.

## Source checkout mount

The public repository may be mounted read-only into containers so agents can inspect their own contracts and docs. Write access should be explicit through project mounts or checked-out working directories.

## High-impact access

Host control is not a default property of an agent container. SSH keys, Docker socket access, host paths, provider credentials, and external channels require reviewed private overlays and capability contracts.
