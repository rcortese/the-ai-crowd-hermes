# Mounts and capabilities

Capabilities are explicit. A container does not receive host power just because Moss is trusted.

## Mount classes

| Class | Example inside container | Default | Rule |
|---|---|---:|---|
| Public source | `/workspace/the-ai-crowd` | read-only | public scaffold truth |
| Agent home | `/opt/data` | read-write | per-agent runtime state; container must run as the deployment checkout UID/GID |
| Shared handoff | `/mnt/hermes-shared` | scoped | handoff artifacts, not secrets |
| Project mount | `/workspace/projects/<name>` | opt-in | explicit named workspaces |
| Private repo | `/workspace/private/<name>` | opt-in | deployment/private state |
| SSH material | `/run/secrets/ssh` | absent | wrapper-only after review |
| Docker control | remote wrapper or socket | absent | prefer wrappers; socket last |
| Host path | narrow path | absent | no broad host mounts |

## Capability classes

- `read_public_repo`: inspect public scaffold.
- `edit_public_repo`: modify versioned scaffold files.
- `git_publish`: commit and push public changes.
- `project_files`: inspect or modify mounted project repos.
- `network_diagnostics`: DNS, ping, curl, netcat.
- `ssh_remote_ops`: SSH-based private infrastructure work through reviewed private key access.
- `container_ops`: Docker/Compose control through reviewed wrappers or mounts.
- `provider_access`: model/channel/provider credentials, always private.
- `external_messaging`: outbound channels, always policy-bound.

## Escalation rule

For each new capability, document:

- purpose;
- owner;
- required mount/credential/tool;
- default state;
- preflight;
- validation evidence;
- rollback or disable path when relevant.

This scaffold documents the model and includes capability and mount policy artifacts. Real host-control mounts remain private deployment choices.
