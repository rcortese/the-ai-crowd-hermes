# Moss capability boundary

Moss may have broader technical capability than other agents, but every capability must be explicit in Hermes.

## Installed tools versus enabled authority

The Moss image may include binaries such as git, GitHub CLI, SSH client, Python, jq, ripgrep, curl, and network diagnostics. Installed tooling is not the same as authority to use private services.

`ops/manifests/*-tools.yaml` files are installed-tool inventories. `ops/manifests/moss-capabilities.example.json` is the public capability/authority example and future capability model. If the two appear to disagree, treat the YAML inventory as package/runtime inventory only and the JSON capability manifest as the authority-contract shape.

## Default available capabilities

From the public scaffold and Moss image, Moss may:

- inspect public repository files;
- run common local shell tooling available in the container;
- use git for local repository inspection and versioning;
- use Python, jq, ripgrep, curl, and network diagnostics against public or explicitly authorized targets.

## Private configuration required

These tools require private credentials, mounts, or policy before they become operational authority:

- GitHub CLI against private repositories or authenticated APIs;
- SSH client access to private infrastructure or private hosts;
- provider/model credentials;
- external messaging/channel integrations;
- project write mounts;
- private reverse-proxy routes.

Use `docs/operations/capability-lanes.md` to move any high-impact capability from disabled/dry-run/read-only toward private live authority.

## Not available by default

- Docker socket or host Docker control;
- private-host SSH keys;
- private provider/channel credentials;
- broad host filesystem mounts;
- OpenClaw gateway/config/session/cron tools;
- OpenClaw heartbeat/reminder behavior, which remains OpenClaw-owned during this migration;
- private memory or session history.

## Escalation rule

A capability is enabled only when its required image packages, mounts, credentials, wrappers, and policy are present. High-impact capabilities require a reviewed private overlay and validation evidence.

## Evidence rule

Before acting through a capability, Moss should identify the concrete access path: mounted file, wrapper, environment variable, service endpoint, or configured tool.

For cutover, also record the status in `docs/operations/cutover-checklist.md`. Review approval does not replace the operator approval for live cutover, private credentials, host control, messaging delivery, or reverse-proxy exposure.
