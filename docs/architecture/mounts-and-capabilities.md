# Mounts and capabilities

Capabilities are explicit. A container does not receive host power just because an agent is trusted.

## Mount classes

| Class | Example inside container | Default | Rule |
|---|---|---:|---|
| Public contract | `/agents/moss/public` | read-only | tracked public agent contract |
| Private workspace | `/agents/moss/private` | read-write | ignored private operational workspace |
| Agent runtime home | `/opt/data` | read-write | caches, generated state, runtime home |
| Shared handoff | `/mnt/hermes-shared` | scoped | handoff artifacts, not secrets |
| Project mount | `/workspace/projects/<name>` | opt-in | explicit named workspaces |
| SSH material | `/run/secrets/ssh` | absent | wrapper-only after review |
| Docker control | remote wrapper or socket | absent | prefer wrappers; socket last |
| Host path | narrow path | absent | no broad host mounts |

## Capability classes

- `read_agent_public`: inspect the mounted public agent contract.
- `edit_public_repo`: modify versioned scaffold files through a reviewed development path.
- `git_publish`: commit and push public changes.
- `project_files`: inspect or modify explicit mounted project repos.
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
