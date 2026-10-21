# External-origin rollout evidence

## Authorized scope

Moss-only authenticated WebUI origin, ordinary agent-authorized no-run writes. No board identity, fabricated heartbeat, ownership takeover or other-persona opt-in. Existing heartbeat protections remain intact.

## Private source

Integration branch `integration/paperclip-external-origin` in three private repositories:

- paperclip-private: `60d018c2b57618cc9733a4dab54a824325a55d35` (API/MCP semantic security review bound to `29f434c577c9c65664172ed385e248f30e7d508a`; later commits only bounded build recipe).
- hermes-webui-private: production modules at `ff647bc4e72b8d3f0dce31f5c10d5672f318e5c5`, payload snapshot `884d10f9ef2f1d0f20a2cb3ed82a35d8768b400d`; real qualification harness `ccb131dd8ca11145cadde334b3e76389362bfa9f` changes only the harness.
- the-ai-crowd-hermes: reviewed activation mechanics `c9cae1a90bf258e213a0f9f7f4cd14ffb309d4bf`.

No public PR/release. Operational Compose checkout remains dirty and was not used as a build context or broadly edited.

## Built artifacts

API candidate `sha256:d3b1d6ca96f23f0df347712a5c4084fd87ac99ac69c3b7ba2db76e9030c1a02f` preserves base `sha256:d2e58200377fe592e39654c468d547c4b7bed3bee13cc174ee4bb19fbe596907`. Existing source preimages of replaced routes/log redaction matched Git base exactly. Full shared/server typechecks succeeded with the effective runtime dependency graph; scoped compiled output and actual router imports succeeded.

Moss candidate `sha256:4048c7597b38fa3d81b0af10dcfeadc5e3c03dd65366e4dfff6bdf14a502606c` preserves base `sha256:8ab3e813b0481043eaddb6ff09e839190a9bb2725f7474bf6b2a105e0291d833`. Python compilation and actual installed MCP/SDK import smoke succeeded. Shared Node-only verifier is included in the installed shared dist subpath.

Context/hashes: active profile `runtime/execution-candidates/paperclip-external-final/context-60d018c2b57618cc9733a4dab54a824325a55d35/manifest.json`. Independent replay verified all 44 payload hashes and byte-identical MCP/shared emissions. The local hash-tag binding was checked before using BuildKit; a bare image ID is not a usable FROM reference for this builder.

## Verified

- WebUI relevant regression set: 144 passed; production-module exact-commit independent security approval.
- MCP: 130 passed, typecheck passed.
- API focal suites: 207 passed, including actual embedded PostgreSQL concurrency/cap/namespace/audit and heartbeat counter regressions. Route suite authentication/services/counter include doubles; not represented as production E2E.
- Activation: 15 sandbox tests passed without expectedFailure, with independent final review. Observation failure is not an automatic rollback trigger. Actual startup failure recovery requires old image/running/healthy readback. Key mode is explicit regardless of umask.
- API promoted through preserved effective Compose inputs. Independent readback: exact new image and healthy state.
- Live API qualification from the exact candidate Moss image: null-proof GET; unknown-write/checkout/invalid-run fail-closed checks; unproved direct PATCH 403; proved PATCH 200 preserving description; comment 201; document 201 and revision/body readbacks. All without a run header.
- Exact real issue: TAC-312, `4f634be3-b5ce-4e9d-b1b9-35280b4949cc`, backlog, no assignee/checkout/execution run. Comment `a37ca3cf-3e4e-42e2-bc0e-1cafc45ca0d8`, actual Moss agent and no user author. Document `external-origin-api-qualification`, revision `589ad6f6-b5a9-4040-8685-558380d524d7`. Parent independently read those targets back.
- Secret metadata readback only: raw32, mode0640, uid99/gid1000; mounted read-only in API. Values were not logged or versioned.

## Remaining operational acceptance

API is active. Moss activation is handed to a bounded host-side executor after current WebUI activity drains, because recreating Moss kills its current agent/tool process. Host log/PID and activation receipts, not this source document, determine whether that later effect occurred. Do not infer Moss promotion merely from this document.

Read active profile `runtime/execution-candidates/paperclip-external-final/activation/{server,moss}.receipt.json` and inspect actual container images/health. Apply script records readiness, not functional acceptance. It preserves the previous immutable image and existing Compose files for recovery; it does not depend on the replaced Moss process.

Live qualification used a synthetic cookie/session fixture and real deployed API, credential, HMAC key and candidate image. It was not a real browser turn by Rodolfo. Required remaining evidence: genuine fresh authenticated WebUI session through the activated attester, native run-bound execution after activation, and operational lost-binding/ownership negatives. Unknown old `api_server` sessions are not retroactively granted birth provenance. Do not close TAC-312 or claim implementation complete before these central results exist.
