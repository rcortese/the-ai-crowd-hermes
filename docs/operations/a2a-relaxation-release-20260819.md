# Release receipt — relaxed Moss A2A, Hermes Agent and WebUI refresh

**Status:** `ACCEPTED`
**Activated source:** `50e237c3bba8a23d64fe74552ffbc21453654632`
**Activation date:** 2026-08-19

## Intent and topology

This release removes the private `MOSS_HERMES_PROTECTED_A2A` guard that prevented ordinary Moss local-profile operation. It retains exactly one configured native A2A peer: **Moss → Denholm**. It does not enable arbitrary A2A peers, direct URLs, persona-RPC substitution, or a Moss A2A listener.

## Source and image identity

| Surface | Identity |
|---|---|
| Hermes Agent source | `27aa96b9ddb09c34f3868f35830368f65892f911` |
| Hermes WebUI source | `fe84511935c78533aaf5ab5518411813753416f7` |
| Stack source at runtime reconciliation | `50e237c3bba8a23d64fe74552ffbc21453654632` |
| Hermes Agent image | `sha256:bf0d3cacbb7f807fa4596dc2e14feefb32895487a531fb72007eed1685d926d7` |
| Moss all-in-one image | `sha256:3ae60c86051c88fc88e638b8464d834a46145d4bb185ef298cfe8e713c7e7fe9` |

The Moss image reports Agent `v0.20.3 (2026.8.16.2)` and WebUI `v0.51.150-4187-gfe845119`.

## Validation evidence

- Candidate title contract and all three causal mutations: `PASS`.
- Candidate build contract: `PASS`.
- Candidate source-closure contract: `PASS`.
- Moss image build executed the selected WebUI regression tranche: `86 passed`.
- All six production containers are healthy with `restart=0`.
- Moss local profiles `scribe` and `reviewer` load their plugin sets without `ProtectedPluginPolicyError`.
- Moss gateway (`8648`) and WebUI (`8787`) respond successfully.
- Native A2A E2E: a fresh Moss session invoked `a2a_call(agent="denholm", ...)`, received `ACK relaxed-a2a-root-1787157147`, and Denholm recorded the inbound task and outbound completion under `task-b39850324b0847a6`.

## Runtime schema reconciliation

The Agent A2A tool resolves configured peers from `a2a_agents.<name>.url`. Older materialized Moss config used `endpoint`, leaving Denholm listed without a usable URL. The activation reconciliation changed only `endpoint: http://denholm:9900` to `url: http://denholm:9900` in:

- `runtime/moss-home/config.yaml`;
- `runtime/moss-home/profiles/moss/config.yaml`.

Preimages and postimage hashes are retained in the canonical backup root:

```text
state/private/backups/a2a-url-schema-repair-20260819/
```

No credential values are recorded in this receipt.

## Non-interference and remaining notes

- No service restart counter increased during post-activation verification.
- The six runtime containers were promoted manually before reconciliation; this receipt validates the resulting live state rather than claiming the deprecated self-replace helper terminalized it.
- The local dashboard endpoint `9119` is not listening in the new Moss image. Gateway and WebUI health are live. This is an observed surface difference, not an A2A or profile failure.
- `TERMINAL_CWD` remains a deprecated `.env` setting; it is unrelated to this release and should be migrated separately.
