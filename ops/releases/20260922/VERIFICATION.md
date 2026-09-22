# Verification of the prepared candidate (no production application)

Upstream releases rechecked: Agent v2026.9.21 (0.21.4), WebUI v0.52.113. Source reconstruction from fresh official-upstream fetches plus the private Git bundles reproduced every build archive byte-for-byte.

Final image validation:
- All six: Python 3.13.5, SQLite 3.53.4, Agent 0.21.4, Node 26, imports, session creation/search.
- All six: actual image entrypoint booted against synthetic state, network none, no host ports or production mounts; local API health answered 200. Moss/Roy WebUI health also answered 200. Fixture containers removed afterward.
- Agent/Moss focused + Honcho + Runs suites: 386 passed; 59 upstream warnings.
- Agent/common (Roy image): 254 passed.
- WebUI approval/fork behavior: 43 passed in Moss, 43 passed in Roy.
- Executor: 18 unit/contract tests passed, including successful transaction receipt, failure→rollback, config preservation, metadata-only connections opt-out, image-only Compose changes, package tamper/path escape refusal, source import, third-image refusal, and unreleased-review refusal. These tests simulate lifecycle; they do not claim a real production or dummy-Compose cutover occurred.
- Real isolated backup/restore rehearsal: authenticated AES-GCM encryption, SQLite online backup and restored integrity, ciphertext tamper rejection, old→new→old messages retained. Old Agent FTS projection bug reproduced by long tool row; upgrade repairs it and old-image reopen of the migrated fixture retains FTS integrity and post-upgrade writes.
- Moss login-shell CLI path verified from the final image as UID/GID 99:100.
- Host read-only preflight passed; durable status NOT_APPLIED.

Build defects caught and corrected: implicit uv Python 3.11 selection; loss of executable bit on upstream docker/entrypoint-dispatch.sh after archive extraction. One npm network timeout was retried successfully. Missing pytest/pytest-asyncio in production-minimal images was resolved only with a read-only disposable test-dependency mount, not by adding development dependencies to production.

Concurrent source reconciliation: production advanced from 85621765 to f96c2428 (Moss login-shell PATH repair), with no image/container change. Candidate stack source fast-forwarded and its recipe preserves that fix. Preflight binds f96c2428e032b72fa50ead64e3cc60b3abafc496.

Remaining gate: independent review did not execute. The official intern wrapper returned HTTP 401 (expired OAuth) on a bounded readiness request. review.json remains BLOCKED and apply refuses it. Source packet remains a review candidate, not an accepted rollout. No public fork push or production lifecycle was performed.

Post-application human acceptance remains necessary for a real browser 'approve only once' click and real Honcho recall; no synthetic test is reported as those live interactions.
