# Retry r2 verification

This packet changes only the host executor/probe, retry baseline, tests and operator documentation. The six candidate images are unchanged from the original sealed build and retain its source/image/backup compatibility evidence below.

## Current checks

- Baseline: production clean at 653ed9d2cd839d079c09472152051ae6b28269ba, all six exact original base images, Docker healthy, zero restarts. Fresh config hashes and exact predecessor ROLLED_BACK transaction digest are in release.json. No production mutation was performed during this repair.
- New packet preflight on MEDIA: authenticated health PASS for all six, PRECHECK PASS; r2 status NOT_APPLIED. The original transaction/backups/source/logs are retained, not reset or overwritten.
- Executor/visual tests: 38 passed. Includes full six-service simulated transaction with delayed Denholm gateway, bounded persistent degradation, immediate permanent errors, readiness-checked rollback, safe structured diagnostics, malformed probe refusal, predecessor hash/terminal gates, real HTTP server + real probe subprocess starting→ready and HTTP401, and detached visual-worker fixtures. Tests simulate production Docker lifecycle; no production or dummy-Compose cutover is claimed. Detached fixture Popen ResourceWarnings are known baseline warnings.
- RED regression: running the delayed-gateway assertion against the predecessor healthy() fails (zero gateway probes); the repaired implementation passes.
- Failure attribution limit: original Denholm child exception was discarded. Logs indicate incomplete gateway/Telegram startup at rollback time, but the exact exception cannot be reconstructed. The proven one-shot readiness defect and missing diagnostics are corrected without relaxing acceptance gates.
- Fresh independent review is mandatory for r2; only a review.json with APPROVED WITHOUT CHANGES bound to current release.json releases apply. Original approvals do not release r2.

## Unchanged image evidence from original release

Agent v2026.9.21 (0.21.4), WebUI v0.52.113; exact source commits and immutable image IDs are in release.json. Fresh official upstream fetches plus private Git bundles reproduced the original source archives byte-for-byte.

All six images passed Python 3.13.5, SQLite 3.53.4, Agent 0.21.4, Node 26, imports and session create/search checks. All six actual entrypoints booted with synthetic homes, no network, no host ports or production mounts; API health was 200. Moss/Roy WebUI health also passed. Fixture containers were removed.

Moss Agent/Honcho/Runs: 386 passed (59 upstream warnings). Roy common Agent: 254 passed. Moss and Roy WebUI focused approval/fork tests: 43 passed each. Real isolated backup rehearsal passed authenticated AES-GCM, SQLite backup/restore integrity, ciphertext tamper refusal, and old→new→old message retention including post-upgrade writes. CLI login shell worked as UID/GID 99:100.

Human post-apply acceptance remains: browser approve-only-once and real Honcho recall. These are not replaced by readiness or synthetic tests.
