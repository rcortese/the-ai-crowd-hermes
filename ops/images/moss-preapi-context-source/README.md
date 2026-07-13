# Moss pre-API WebUI context overlay

Purpose: restore the coherent pre-Runs WebUI/backend lifecycle while retaining the fail-closed context indicator.

## Immutable validation anchors

- Base tag: `the-ai-crowd/moss-all-in-one:rollback-before-webui-api-intermediate-prod-20260701T044611Z`
- Expected base image ID: `sha256:31a88b842a2356f70538c4e441e38e235333e6274fd031ce78cad469ce4ed861`
- Validated reproducible candidate image ID: `sha256:adfdd874dbd08847a103464cdbdafee90e970f734b31039b3a7fcbb3ce0ef9e7`
- Base `ui.js`: `a10a90f175f80893b2ff47f7bf1896931059911261f9217d7f7036f80cbfa176`
- Overlay `ui.js`: `103a13a48e1729e09678a2d4c96f0282e1cfebe8b8cfd11f1b0d95705738328f`

Use `./build.sh [optional-tag]`. It fails closed if the base tag no longer resolves to the expected image ID and verifies the final `ui.js` checksum. The overlay changes only the context indicator: no fixed 128K default, and percentage is shown only when prompt occupancy and an explicit context window are both known.

## Behavioral evidence

The validated candidate passed the same browser scenario in isolated dev and in the Roy production canary:

- explicit queue marker remained queued;
- steer returned HTTP 200 with `accepted=true` and the original stream ID;
- queue remained intact after steer;
- no `/v1/runs` requests;
- no browser errors;
- cancel, reload and bounded compact completed;
- disposable sessions were removed and absence verified.

Moss promotion requires a host-side idle gate, rollback tag created from the running Moss image ID, reviewer approval, app-level Moss persona validation, and automatic rollback on any failed gate.
