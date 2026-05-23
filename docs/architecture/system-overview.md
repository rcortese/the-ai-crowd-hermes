# System overview

The AI Crowd Hermes scaffold is the public, reproducible shell for running The AI Crowd agents as separate Hermes containers.

## Core idea

The public repository describes the runtime shape, contracts, validation, and safe extension points. Private production checkouts add credentials, state, provider configuration, local topology, and nested private repos without committing them to public git.

## Agents

- **Moss**: technical operations and Hermes/OpenClaw migration execution. Production-enabled first.
- **Richmond**: ArchiveOps stewardship. Profile-gated until separately validated.
- **The Elders**: packet-only archive knowledge. Profile-gated and intentionally constrained.

Other agents may be represented later only after their ownership and runtime boundaries are explicit.

## Glossary

- **Hermes scaffold**: the public Docker/Compose/repo skeleton without private deployment state.
- **Moss**: the technical-operations agent, running on Hermes with explicit layers, capabilities, mounts, kanban workflow, validation, and private-state boundary.
- **Agent home**: the per-agent writable runtime directory mounted into an agent container.
- **Capability**: an ability enabled by image packages, tools, wrappers, mounts, credentials, or external services.
- **Handoff**: explicit transfer of ownership or bounded consultation between agents.
- **Review gate**: artifact-versioned independent approval checkpoint.
- **Private state**: credentials, OAuth/auth files, sessions, local topology, private repos, private memory, or deployment-specific runtime data.

## Public reading path

1. Start here.
2. Read `public-private-boundary.md` before adding files.
3. Read `agent-container-model.md` to understand container/home separation.
4. Read `moss-architecture.md` for Moss-specific layers.
5. Read `mounts-and-capabilities.md` before adding mounts or tools.
6. Read `kanban-workflow.md` before modeling cross-agent work.
7. Use `../../schemas/` and `../../tests/` for validation.
