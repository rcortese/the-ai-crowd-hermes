# System overview

The AI Crowd Hermes scaffold is the public, reproducible shell for running The AI Crowd agents as separate Hermes containers.

## Core idea

The public repository describes the runtime shape, contracts, validation, and safe extension points. Private production checkouts add credentials, state, provider configuration, local topology, and nested private repos without committing them to public git.

## Agents represented as examples

- **Moss**: technical operations, infrastructure, runtime and incidents.
- **Jen**: productivity, tasks and Calendar.
- **Denholm**: product stewardship and cross-agent coherence.
- **Roy**: personal assistance for the configured operator.
- **Richmond**: archive stewardship.
- **The Elders**: approved packet-only answers.

No enabled service, active credential or deployment status is implied. The Compose example uses explicit image/mount variables and separates read-only `/contracts` from private `/workspace` and `/runtime`.

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
