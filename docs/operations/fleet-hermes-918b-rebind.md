# Fleet Hermes 918b rebind packet

Status: **source-only and quarantined**. This packet binds the reviewed v3 base source to the fleet persona-builder contract; it performs no build, pull, tag, push, registry, Compose, or runtime action.

`ops/manifests/fleet-hermes-918b-rebind.lock.json` pins the final v3 tag, the required local image-ID slot, and the exact 918b source tuple. The slot is intentionally `null`: no local image ID was observed or created by this source candidate. `ops/release/fleet_hermes_918b_rebind.py --require-local-image-id` therefore fails closed until a separately authorized, immutable image-binding change supplies a verified `sha256:` ID.

The persona builder must resolve the pinned tag locally and require that its resolved ID equals the bound immutable ID before it can build. It labels resulting candidates with the rebind tag, resolved base ID, and the exact Hermes source tuple.

A2A overlay builders are explicitly quarantined from the full-base rebind path. Their role remains a reviewed subset-copy overlay; neither A2A overlay Dockerfile nor builder is a substitute for a complete Hermes-base rebind.
