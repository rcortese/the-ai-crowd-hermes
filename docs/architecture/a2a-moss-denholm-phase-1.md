# A2A phase 1 — Moss to Denholm

**Status:** deployment candidate; not activated.
**Scope:** native Hermes A2A v1.0, one directed edge: `Moss ──A2A──> Denholm`.

## Revised decision

Adopt Hermes' native A2A transport for the first remote product-stewardship consultation, replacing the unmaterialized `persona_rpc` runtime dependency on this edge only. The decision/authority remains Denholm's; A2A carries the request and response without creating a fallback authority.

The initial graph is deliberately asymmetric:

```text
Moss ──A2A──> Denholm
```

- Moss has one registered A2A client tool and one approved outbound peer: `denholm`.
- Denholm is the only A2A listener. It authenticates the bearer token as identity `moss`, then authorizes that identity through `A2A_TRUSTED_PEERS=moss`.
- The listener is internal Compose-only on port 9900; no host port is published.
- The candidate removes direct-URL egress, Agent Card discovery, history and fan-out from Moss's exposed A2A tool surface.
- A task transport failure is technical failure, not a decision. A required Denholm decision that cannot be obtained remains `BLOCKED_AUTHORITY`; there is no per-request fallback to another persona or to legacy RPC.

## Why this is the first cut

1. **Fixes the operative gap.** The policy names `persona_rpc`, while the live Moss image does not provide its server-side executable/tool registration. Native A2A is present in Hermes 0.20.0 and can be enabled without caller-controlled credentials.
2. **Limits trust and blast radius.** One directional credential, one authenticated identity, one target and one service-scoped rollout are auditable. A mesh would multiply token, retention, routing and cancellation surfaces before a real edge has been proven.
3. **Separates authority from transport.** Denholm remains required for `product_stewardship`; this candidate does not give Moss product authority and does not alter Roy, Viviane, Rodolfo or Moss boundaries.
4. **Fails closed at the caller.** Peer selection is configuration allow-listed (`a2a.outbound_trusted_peers: [denholm]`); URL-shaped agents are rejected and unregistered client operations cannot be invoked through the active toolset.
5. **Preserves deployment discipline.** Moss and Denholm receive independent immutable overlay images, each labeled with candidate commit/tree and exact plugin preimage. Image build, selector change, configuration mutation and service recreation remain separate gates.

## Future architecture: star, not current state

The intended expansion, after phase-1 evidence and a separate approval, is a star centred on Moss:

```text
                  Jen
                   ↑
Richmond ←── Moss ──→ Denholm
                   ↓
                  Roy
                   ↓
             The Elders
```

This drawing is **not** an enabled topology, a trust grant, or a deployment plan. Each future edge requires its own decision authority, token, outbound allow-list entry, receiver trust rule, data-retention assessment, negative tests and staged rollout. The star is preferred over a peer mesh because it keeps routing/accountability at the operational coordinator and grows trust relationships linearly instead of quadratically.

## Candidate contents

- `compose.yaml`: enables only Denholm inbound A2A; supplies the directional token by externally managed environment; exposes port 9900 only to the internal network.
- `ops/images/Dockerfile.runtime-a2a-moss-denholm`: overlays a preimage-bound restriction onto the shipped A2A plugin.
- `ops/scripts/patch-a2a-moss-denholm-plugin.py`: makes named configured peers mandatory and registers only `a2a_call`.
- `ops/scripts/prepare-a2a-moss-denholm-config.py`: validates and stages the required Moss/Denholm config delta with atomic writes and explicit backups when invoked with `--apply`.
- `ops/scripts/build-a2a-moss-denholm-candidate.sh`: produces non-activating, source-labeled Moss and Denholm images.

## Activation gates

1. Re-read production Compose HEAD, dirty-path overlap and base-image IDs; do not activate from a moved or overlapping source state.
2. Generate `MOSS_TO_DENHOLM_A2A_TOKEN` in the approved secret store/env file; never commit, print or reuse it as a Persona RPC token.
3. Run config preflight, then apply it with backups in the designated backup root.
4. Build both source-bound images and verify labels, IDs and the restricted registered tool set.
5. Update only `MOSS_IMAGE_REF` and `DENHOLM_IMAGE_REF` to the immutable candidate IDs, render Compose, and verify no host A2A port is published.
6. Recreate **Denholm first**, validate unauthenticated/incorrect-token/untrusted-peer denial and successful Moss identity admission; then recreate Moss.
7. Perform one real Moss→Denholm product-stewardship request and verify a closed result, task/audit correlation and caller-visible outcome.
8. Keep legacy `persona_rpc` configuration unchanged until the A2A edge is proven and the separate retirement decision is approved. No runtime fallback is permitted.

## Rollback

Rollback is selector/configuration rollback only: restore backed-up config files, restore the prior immutable image selectors, recreate Denholm then Moss, and verify the pre-cutover health projection. Do not rotate, delete or reuse credentials during rollback; revoke the phase token only after the old state is healthy and evidence retention has been decided.
