# Capability policy

Capabilities are explicit operating authority. A binary existing in an image does not mean Moss may use it against private systems.

## Three layers

1. **Installed tool**: package or binary exists.
2. **Declared capability**: manifest documents what the tool can do and what authority is needed.
3. **Enabled authority**: private deployment supplies credentials, mounts, wrappers, or config and passes preflight.

## Capability classes

- `read_public_repo`
- `edit_public_repo`
- `git_publish`
- `project_files`
- `network_diagnostics`
- `ssh_remote_ops`
- `container_ops`
- `provider_access`
- `external_messaging`

## Required fields for escalation

Before enabling a private/high-impact capability, document:

- purpose;
- owner;
- required mount, credential, or wrapper;
- default state;
- preflight command or checklist;
- validation evidence;
- disable path.

## Default safety

Moss may be a trusted technical operator, but Hermes should still make authority inspectable. Trust is represented through reviewed capabilities, not hidden broad mounts.
