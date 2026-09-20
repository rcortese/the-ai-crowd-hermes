# The AI Crowd stage 2 execution inventory

Capture: 2026-09-20T19:28:06-03:00 on MEDIA. Sanitized read-only runtime and source custody inventory for the six-row matrix.

## Effective topology

- Compose project: the-ai-crowd.
- Workdir: /mnt/user/appdata/the-ai-crowd.
- Effective Compose file for all six targets: /mnt/user/appdata/the-ai-crowd/compose.yaml.
- Rendered service set is exactly moss, roy, jen, denholm, richmond, the-elders.
- Operational source: /mnt/ssd/appdata/the-ai-crowd, branch main, clean and six commits ahead of origin/main; it needs a per-command safe.directory override because ownership is nobody:users.
- Canonical release candidate: /mnt/ssd/appdata/the-ai-crowd-candidates/update-20260916/the-ai-crowd-full-release, branch candidate/full-stack-release, clean at f627e0e2b40b85fc68c0913a01cfa2dfb001340d, root-owned and distinct from active build context.

## Runtime baseline

- All six target containers were running and healthy with restart count zero.
- Moss: Agent 0.20.0; immutable image ID sha256:1b6f460b5afb5a8ef7d5069230186f549cce6f3b854112ddc8c200a756ef4150; WebUI installed, host port 8644; supervisord runs gateway, WebUI and two private MCP helpers.
- Roy: Agent 0.20.3; image the-ai-crowd/roy-all-in-one:20260819-relaxed-a2a; WebUI installed on internal ports 8645 and 8644; supervisord runs gateway, dashboard and WebUI.
- Jen: Agent 0.19.1; image the-ai-crowd/jen:release-ceec74beb2cc46095600ba8e3b7f6aa9970453d3; WebUI not applicable; s6 runs default and gateway-jen plus dashboard 9121.
- Denholm: Agent 0.19.1; image the-ai-crowd/denholm:release-4e83d7d17913; WebUI not applicable; s6 runs default and gateway-denholm.
- Richmond: Agent 0.19.1; image the-ai-crowd/richmond:release-ceec74beb2cc46095600ba8e3b7f6aa9970453d3; WebUI not applicable; s6 runs default gateway only.
- The Elders: Agent 0.19.1; image the-ai-crowd/the-elders:release-ceec74beb2cc46095600ba8e3b7f6aa9970453d3; WebUI not applicable; s6 runs default gateway only.

## Preserved boundaries

- Every persona has its own persistent /opt/data mount.
- Moss exposes runtime snapshot mounts for /agents/moss/public and /agents/moss/private as read-only overrides; they are not source checkouts.
- Roy has private-workspace and personal-assistant source bindings.
- Jen, Denholm, Richmond and The Elders have independent public/private mounts, read-only ArchiveOps and shared/auth mounts.
- Future builds and deploys must compare these sources, destinations and modes against matrix G06/G07.

## Enabled non-bundled plugins

- Moss: claude-code-tool 0.1.0, hermes-lcm 0.19.0, lifecycle-authorization-guard 1.18.0.
- Roy: personal-assistant-integrator 3.0.0, roy-pdf 1.1.0; roy-viviane-fiscal is present but disabled.
- Jen: hermes-lcm 0.11.1 plus jen_calendar_process, jen_document_task_candidates, jen_todoist_process and jen_weather_process.
- Denholm: hermes-lcm 0.11.1. Richmond and The Elders: no enabled non-bundled plugins.
- Credentials, recipient IDs, configuration values, sessions, auth data and message content were not inspected or retained.

## Candidate and lifecycle result

- ops/scripts/release-moss-agent-webui.sh is Moss-only: it names only the-ai-crowd-moss-1, builds one image and invokes Moss HDDT cutover. Its gates may be reused as reference, but it is not a fleet deploy script.
- lifecycle-authorization-guard correctly blocked a command whose remote shell content could affect or disconnect Moss before execution. It requires a short-lived root-owned read-only single-use receipt bound to the exact normalized command SHA-256 and consumed by the external socket.
- No receipt was issued or consumed; no guard was removed or bypassed. Read-only preflight SSH probes were demonstrated usable.

## Decision

- INPUT_GATE_READY for Stage 3 source and release discovery: topology, runtime targets, mount boundaries, versions, candidate custody, supervision and plugin exceptions are identity-bound.
- INPUT_GATE_PENDING for builds and fleet promotion: exact upstream trees and fork disposition are not frozen; six candidate images and receipts do not exist; no fleet executor exists; no external receipt exists for Moss-affecting lifecycle commands.
