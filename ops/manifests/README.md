# Tool inventories and capability examples

This directory distinguishes installed tooling from enabled authority.

## Installed-tool inventories

`*-tools.yaml` files describe packages and command-line tools included in each agent image. They are image inventory, not permission grants.

Examples:

- `moss-tools.yaml`: broader technical-ops tool inventory for Moss.
- `richmond-tools.yaml`: constrained ArchiveOps-oriented tool inventory.
- `the-elders-tools.yaml`: packet-only/minimal tool inventory.

## Capability examples

`moss-capabilities.example.json` is the public example for the future capability/authority model. It describes capability IDs, status, requirements, preflight checks, and evidence expectations.

A tool being installed in an image does not mean the agent has authority to use it against private systems. Authority requires the relevant private configuration, mounts, credentials, wrapper policy, review gate, and validation evidence.
