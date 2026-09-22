# The AI Crowd — stable-release operator packet

Status: PREPARED CANDIDATE, NOT APPLIED. The exact release.json digest must have an independent approval in review.json before manual apply; the script enforces this gate. See review.json for the current verdict. Never bypass or invent approval.

## Scope

Six personas: the-elders, richmond, denholm, jen, roy, moss (Moss last).
Agent upstream v2026.9.21 / 0.21.4, commit d337b736aa1e8ebecfab043842d13e4a2d2f48a3.
WebUI upstream v0.52.113, commit c67fd2dd270a1128c2754200406bca58e9d9a25a (Moss and Roy only).
Upstreams reconfirmed through GitHub release APIs. Newer experimental WebUI tags intentionally excluded. Upstream issue nesquena/hermes-webui#6008 describes the empty approval ID; fixes on master are not in this stable release.

## Customization disposition

Agent: preserve HERMES_AUTH_HOME, ordered registered-provider search fallback, direct-human memory admission floor, and narrow manual-approval floor. Remove a redundant private test stub now supplied upstream. Historical release scripts/docs were not transplanted into runtime source.
Moss: preserve authenticated Honcho admission, signed API request/browser-session scope, exact peer/workspace binding. Three-way port retains upstream worker lifetime accounting and session/cwd metadata. No import of historical memories or change to Honcho server/database.
WebUI: stable already equals the previous fleet stable base; retain the existing selective AI Crowd ports (persona proxy boundaries, health/auth, honest context meter, selector order, topic-first titles, ownership barrier). Carry Agent request_id through card approval_id and send it back as request_id, including stale/replayed request tests. Preserve Moss Honcho cookie/signature integration.
Runtime: derive each image from its own pinned live image, keep Python 3.13.5, SQLite 3.53.4, Node 26 and persona-specific dependencies. Pin Python explicitly so uv cannot downgrade it to 3.11. Keep retired plugins retired. Every source revision and tree is image-labeled; source-only Git bundles preserve the port commits.
Config: add only known_builtin_toolsets metadata recording the existing absence of connections as an explicit choice; do not change platform_toolsets, credentials, models, identity, or _config_version. Do not migrate other profiles or overwrite SOUL/skills.

## Operator entrypoint (root@media.lan)

bash /mnt/user/appdata/the-ai-crowd-candidates/release-20260922/operator/run-host.sh check

Only after review release, the same script with `apply` asks for APLICAR and starts a host-side nohup executor. It does not depend on Moss staying alive. Use `status` to read the durable transaction receipt. Do not send messages or start tasks while the update is running. A busy/unknown queue refuses interruption.

`check` validates exact source HEAD, clean worktree, package hashes, live image IDs, candidate IDs, mounts, health, config hashes, and a Compose render differing ONLY in image selectors. It makes no production changes.

`apply` creates fresh per-database SQLite online snapshots plus runtime configuration snapshots, encrypts using the authenticated AES-GCM envelope, and restores/checks database integrity in tmpfs before mutation. Keys and ciphertext remain under the private backup root (not a replacement for off-host backups). It imports the hash-bound operator/source packet into ops/releases/20260922 and commits that directory plus compose.yaml on the host; unrelated source/config changes are rejected by preflight. Rollback preserves the release source as an audit/rebuild artifact and changes only the image selectors.

Rollback changes image selectors only, preserves accepted database writes, and takes another fresh encrypted backup. Synthetic old→new→old DB rehearsal is required as evidence; this is not a claim that every future incompatible DB can be downgraded. Never manually restore the pre-upgrade DB over current messages. `recover` is for a nonterminal interrupted transaction and uses its exact receipt. SIGKILL/host failure requires operator reconciliation; this is not a HA system.

## Known release gates

Independent review is bound to release.json by review.json. OAuth was restored and the first review requested detailed rollback evidence and old-image config compatibility proof. evidence/rehearsal-detailed.log records a fresh real-image old→new→old DB rehearsal, authenticated snapshot verification and candidate/base entrypoint health with migrated synthetic configuration. rehearsal.py reproduces it from the candidate build directory (operator/ contains this packet). Only synthetic state, network none and no published ports are used.
A real browser approval click and real Telegram/Honcho recall can only be accepted after user-operated deployment; image unit tests do not claim these live interactions occurred.
The script is a candidate until isolated backup, migration/rollback, host preflight, and transaction tests are recorded and the review gate is released.
No production lifecycle or config/source mutation has been performed by Moss during preparation.
