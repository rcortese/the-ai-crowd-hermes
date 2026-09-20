# The AI Crowd — stage 2 corrected execution inventory

Status: INVENTORY_COMPLETE_WITH_EXECUTION_BLOCKER. This replaces the incomplete 49-line inventory at 755005309ee083df166f34a25a82462d4ef9a527. It is not release readiness, approval of six candidate images, or authorization to deploy. The original stage-2 plan explicitly allows an exact impeded action and required intervention to be reported when a blocker remains. The isolated container-test lane remains blocked; build-only capability was exercised.

## Scope and evidence

The authoritative plan is session f8b464ffe8a4, stage 2; stage-1 matrix is `the-ai-crowd-fleet-scope-matrix-v1.json`, created at f627e0e2b40b85fc68c0913a01cfa2dfb001340d. Six targets: moss, roy, jen, denholm, richmond, the-elders. WebUI applies only to Moss and Roy. This work does not freeze upstream releases, reconcile all fork behaviors, repair production, build the fleet, or implement fleet deployment.

Machine-readable companion: `the-ai-crowd-stage-2-evidence-v1.json`. It contains independent before/after Docker projections, full mount source/destination/mode, Compose projection, supplemental files, discovered profiles, configured toolsets/plugins, command availability, process home/environment allowlists, configured routes, and network aliases. Collection completion timestamps are UTC file mtimes of the fresh captures, not container start times. Container StartedAt remains 2026-09-18; the captures are from 2026-09-20. These are sequential observations, not an atomic fleet snapshot.

Sanitization: no environment values except home/path and explicitly allowlisted routing host/port/enable fields; no tokens, auth files, channel recipient IDs, database/session/message content, full process environment, or environment-file contents. Credential presence is retained only as a channel category. Configured toolsets and enabled plugin declarations are not proof of runtime tool invocation. Platform toolset entries do not prove that their channels are enabled or connected. No message was sent to a real recipient.

## Detailed execution and review plan

1. Recover original plan and stage-1 matrix; bind current MEDIA SSH identity and existing release branch; retain baseline container IDs/images/start times/restarts and full topology.
2. Render the exact labelled Compose file from its labelled project directory. Inventory its complementary env files and interpolation file by path/presence only. Compare declared image selectors and mounts with created containers; preserve extra live networks separately.
3. Read sanitized persona configuration, process/supervisor metadata and path availability. Distinguish root home, merely present profiles, actual running gateway home, and configured versus observed routes/tools.
4. Classify all existing update-20260916 candidates and historical captures. Keep the consolidated stack candidate as sole documentation/build-source edit authority; do not write into runtime snapshots.
5. Exercise minimal isolated build capability and attempt a zero-production-mount, no-network container smoke. Never interpret preventive refusal as a failed application test, and never disable guards to get a green result.
6. Incorporate an independent plan review. Prepare only this inventory and its sanitized evidence companion; validate schema/service coverage, stage-1 binding, before/after equality, Compose parity, and sensitive-content exclusions. Ask an independent reviewer to inspect exact hashed final bytes while the writer performs its own validation.
7. Version only those two files in the existing candidate. Re-read remote hashes, check commit/diff/cleanliness, and recheck production identity/health after the commit. Any material document change after review requires renewed review.

## Effective production and source custody

Host MEDIA, SSH alias `media`, root UID 0. Compose project `the-ai-crowd`; labelled project directory `/mnt/user/appdata/the-ai-crowd`; all six containers label exactly `/mnt/user/appdata/the-ai-crowd/compose.yaml`. Current file SHA-256: 2fb963899f1abedeb699f869b08e64db1fc44fe71c827cc2b6f588529a9b614d. Explicit `docker compose --project-directory ... -f ... config --no-env-resolution --format json` renders exactly six services and no build sections. Their image selectors and all bind source/target/RW tuples match inspect.

Complementary files: `.env` exists in the project directory; Moss uses `env/fleet.env` plus absolute `env/moss-webui.env`; Roy uses absolute `env/roy-v3.env`; the other four use `env/fleet.env`. All exist. No `include`, `extends`, or service profiles occur in the inspected production source. A `compose.project-mount.example.yaml` exists, but is not in the creation labels or this explicit render. Historical shell interpolation cannot be reconstructed from labels; observed containers, not the present render alone, are the execution authority.

Operational checkout: `/mnt/ssd/appdata/the-ai-crowd`, main, clean, HEAD ee05471ed3e83f950f3e965572fe40d2352ee3d5, six commits ahead of its locally recorded origin/main. This is not a fresh remote comparison. Use a per-command safe.directory setting there; do not change global Git trust.

Edit/version authority: `/mnt/user/appdata/the-ai-crowd-candidates/update-20260916/the-ai-crowd-full-release`, branch `candidate/full-stack-release`, input HEAD 755005309ee083df166f34a25a82462d4ef9a527, tree 0bcc6ab0852602d13d10b0ee67f1e43850e6f394. Root-owned mode 0755 and writable via the verified SSH identity. It is distinct from the operational checkout. Actual publication of the two files and the local commit provide the final write proof; this is not a claim based only on mode bits.

Unraid appdata policy is cache-only on pool ssd. Both candidate parent path views resolve to device 52/inode 219473992 and btrfs /mnt/ssd. Preserve the `/mnt/user/...` literal for Compose and command identity; inode equivalence does not merge authorization identities. No data were copied between share and pool views.

## Existing candidate disposition

All four component checkouts below were clean, root-owned 0755. They have fork/upstream remotes (Agent: rcortese/hermes-agent and NousResearch/hermes-agent; WebUI: rcortese/hermes-webui and nesquena/hermes-webui). No fetch, push, rebase, cherry-pick, or fork acceptance occurred.

| Directory under update-20260916 | Branch and HEAD | Reuse decision |
| --- | --- | --- |
| hermes-agent | candidate/v2026.9.14; dc64dc6c3e717560d0c3cd7fb36d060d18705e5c | Retain comparative selective-port source: recent commits explicitly cover shared auth, web fallback, human-only persistence, approval floor, upstream web contracts. Do not mistake it for the complete live delta. |
| hermes-webui | candidate/v0.52.113; 64918590cdb4d5cc08e9968213a49389d0c6babd | Reuse existing WebUI candidate and fork-extension/selector changes. Stage 4 still must verify remote-runtime resolution against the alternate fork and runtime; no claim all ports are accepted. |
| hermes-agent-live-reconstructed | reconstructed/live-v0.20.0; 0d1b18033427c0f7f98c60034b9a3cdbe180d3c6 | Retain as provenance/comparison baseline. History includes live v0.20.0 delta reconstruction; not the new release source or a deployable candidate. |
| hermes-agent-liveport-v2026.9.14 | candidate/liveport-v2026.9.14; 12f3b6a9eeeb917268592e8a1e85eab7cb94c8cb | Reuse as primary live-port assessment input named by the plan. Recent release/render/build fixes are useful evidence, but include Moss-focused assumptions; not fleet readiness. |
| live-moss-hermes-metadata | Non-checkout capture; pyproject.toml and hermes_cli_init.py | Retain historical provenance only; not editable source authority. |
| live-moss-hermes-source | Non-checkout capture; Agent/gateway/plugins/tools/tests/lock/source files | Retain comparison material for live-code differences; never silently promote it as release source. |
| the-ai-crowd-full-release | candidate/full-stack-release; input HEAD above | Reuse stack Dockerfiles, builders, tests and matrix in place. Only the two stage-2 documentation/evidence files change now. |

Builder inspection: `build-persona-base-candidate.sh` consumes the old protected-base lock for all six; `build-roy-all-in-one-candidate.sh` additionally hardcodes base commit a2bddaf9921c8b8b10f96e188bb61f0a33d9bfc5/tree 9f483dffbf04b33efb4e7bffd3a0a7247f82e223. These are stage-5 corrections, not presently usable latest-version builders. The Moss all-in-one builder exports clean Agent/WebUI trees and requires immutable base, private Node/Playwright inputs and receipt root; preserve those input checks rather than copying a new builder. `release-moss-agent-webui.sh` remains Moss-only, not a fleet executor.

## Six-persona operational inventory

For exact per-channel toolsets, plugins, installed command paths, mount literals and image identities, use the companion service rows. Every observed gateway has HOME=HERMES_HOME=/opt/data, with no HERMES_PROFILE environment override. A named directory is not evidence of an active named-profile gateway.

| Service | Present profiles / observed supervision | Configured routes and distinctions |
| --- | --- | --- |
| Moss | moss and reviewer directories; only reviewer has a separate config in the scanned set. Supervisor gateway and WebUI RUNNING; dashboard FATAL (exited too quickly). Two private MCP helpers observed as gateway descendants, not independent Supervisor programs. | Gateway API 0.0.0.0:8648; webhook 8644; WebUI 8787, backend gateway -> http://moss:8648. Host published port 8644 belongs to the webhook port mapping, not directly WebUI 8787. Telegram credential category present; A2A target name denholm configured. |
| Roy | No named profiles; Supervisor gateway/dashboard/WebUI RUNNING. Dashboard loopback 9123. | API 8645; webhook 8644; WebUI 8787, backend api_server -> http://roy:8645. Telegram credential category present. Only personal-assistant-integrator and roy-pdf enabled; root toolsets restrict Roy to its assistant capabilities. |
| Jen | jen directory/config present. s6 supervision includes gateway-default and gateway-jen/log; only one real gateway command observed, root /opt/data. Dashboard process on loopback 9121. | API 0.0.0.0:8642. Telegram credential category present. Todoist MCP configured; four Jen process plugins plus hermes-lcm and disk-cleanup declared enabled. No WebUI. |
| Denholm | denholm directory/config present. s6 includes gateway-default and gateway-denholm/log; only one real gateway command observed, root /opt/data. No dashboard process observed. | API 0.0.0.0:8643. Telegram credential category present; a2a-platform enabled and A2A toolsets declared. Exposed 9900 is metadata, not an independently verified listener. No WebUI. |
| Richmond | No named profiles; s6 gateway-default and log; one root gateway. | API 0.0.0.0:8646; no Telegram/Discord/Slack credential variable observed in the process. No enabled external-plugin declaration in root config. No WebUI. |
| The Elders | No named profiles; s6 gateway-default and log; one root gateway. | API 0.0.0.0:8647; no Telegram/Discord/Slack credential variable observed in the process. No enabled external-plugin declaration in root config. Shared mount is RO, unlike most peers. No WebUI. |

Moss dashboard FATAL is a newly documented preexisting condition, not caused or repaired here; `healthy` must not hide it. Its cause is not diagnosed by this inventory. Preserve this exception in later candidate validation; do not silently treat the dashboard as working.

No bind replaces /opt/hermes or /opt/hermes-webui directly. Runtime homes do overlay config/plugins/tools; persona public/private mounts overlay identities, project instructions and helpers. Moss public/private mounts are RO runtime snapshots, not editable source. Roy `/opt/personal-assistant` is RO code and `/agents/roy/private` is a separate RW workspace. These exceptions require comparison in later build/runtime tests. A Moss image rebuild alone cannot represent the fleet.

## Build/test capability and exact remaining blocker

Build-only probe executed on MEDIA: `docker build --network none --pull=false --tag stage2-execution-probe:20260920 -`, with stdin Dockerfile `FROM scratch` and two nonproduction labels. Exit 0; immutable result sha256:7e9ce30ecdf613ca7be85684889125a219e7a742e75dc6a98c6fb92251b354f9; separately inspected. The image is intentionally retained and is not a release candidate. This proves basic builder access only: no RUN, dependency fetch, persona source build, or full builder script was tested.

Container smoke was refused by lifecycle-authorization-guard before host execution. Exact outer command and SHA-256 are in the companion blocker record. Intended container: `stage2-isolated-lane-probe`; immutable existing Moss image, overridden Python entrypoint, network none, rootfs RO, no bind mounts, no published ports, cap-drop ALL, no-new-privileges, resource limits, nonroot UID, no healthcheck, automatic removal. No gateway, scheduler, bot or WebUI would be started by the intended entrypoint. This is a blocked capability probe, not an application-test failure and not a demonstrated allowed lane.

Intervention: the external authorization authority must evaluate that exact command and provide the guard's short-lived UID-0 read-only single-use receipt, bound to its normalized SHA-256, consumed by the external root-owned Unix socket. Current runtime default `/run/moss-lifecycle-authorizations/consume.sock` is absent. Moss must not self-issue a receipt, suppress the guard, or reuse a receipt for another command. Alternatively, Rodolfo can arrange the same bounded test through an authorized external host execution lane and return a command-bound receipt. This inventory is not an instruction to deploy or to experiment with a partial fleet script.

The earlier phrase “correctly blocked” is withdrawn. A refusal establishes a blocked action; it does not prove the classifier correctly distinguished read-only inspection, isolated tests and production lifecycle. Some broad read-only probes were also refused. Narrow static reads and direct Docker inspection succeeded without changing protections. The isolated run remains unexecuted.

## Review and exit criteria

A Claude no-tools plan review attempt returned exit 1 / OAuth expired (401), despite auth-status reporting logged in; it produced no technical verdict. The existing Hermes reviewer profile then completed an independent plan review in parallel, requesting provenance, before/after comparisons, explicit configuration-vs-function distinctions and exact blocker/intervention records. Those requirements are incorporated here. Its mistaken reading of StartedAt as capture date is explicitly corrected by timestamped capture metadata.

Final review is of this file plus the evidence companion by exact hashes; the final response records its outcome and the resulting Git commit. The independent reviewer has no write role. Documentation approval does not approve the container-test lane or production promotion.

Exit outcome: inventory/source-custody and existing-candidate reuse are documented; minimal build capability demonstrated; isolated container testing BLOCKED with exact intervention; production functional health not asserted. Stage 3 release discovery can proceed, but candidate tests/build repairs and fleet readiness remain gates of stages 4–9. No production restart, recreate, config change, push or deployment occurred. No persistent behavioral rule, skill or other persona profile was edited.
