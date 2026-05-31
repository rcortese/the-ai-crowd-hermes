# Kanban dispatch-owner patch: pinned fork workflow

This stack no longer relies on loose `ops/patches/*` artifacts for the Kanban dispatch-owner feature.

## Source of truth

- Agent source: `https://github.com/rcortese/hermes-agent.git`
- WebUI source: `https://github.com/rcortese/hermes-webui.git`
- The all-in-one image must pin immutable SHAs in `ops/images/Dockerfile.moss-all-in-one`:
  - `HERMES_AGENT_REV`
  - `HERMES_WEBUI_REV`

The historical patch artifacts under `ops/patches/` are evidence/rollback aids only. Do not apply an upstream update by replacing the checkout and dropping those patches; first port the feature into the public forks, push the fork commits, then update the pinned SHAs.

## Required update sequence

1. Inventory live stack and dirty tree from `/mnt/user/appdata/the-ai-crowd`.
2. Clone/update the public forks in a runtime work directory, not in the production git tree.
3. Port the dispatch-owner behavior onto the current fork heads.
4. Run focused source tests before pushing:
   - Agent: `tests/hermes_cli/test_kanban_boards.py` and `tests/plugins/test_kanban_dashboard_plugin.py`.
   - WebUI: `tests/test_kanban_bridge.py`, `tests/test_kanban_bridge_dispatch_owner.py`, `tests/test_kanban_owner_patch_semantics.py`, and `tests/test_kanban_owner_ui_behavior.py`.
5. Push fork commits and record immutable SHAs.
6. Update `ops/images/Dockerfile.moss-all-in-one` to those SHAs.
7. Ensure the Dockerfile build gates run the same focused Agent/WebUI tests. A skipped “legacy local gate” is a failure of procedure, not a pass.
8. Build a separate candidate tag first, for example `the-ai-crowd/moss-all-in-one:dispatch-owner-candidate`.
9. Smoke the candidate with production delivery disabled and separate runtime/shared state.
10. Validate less-critical containers before touching Moss.
11. Recreate Moss only through a host-side external actor that writes logs/markers under `runtime/moss-home/ops/cutovers/`.

## Minimum candidate gates

The candidate image must prove:

- `/opt/hermes` is at the pinned Agent SHA.
- `hermes_cli.main kanban dispatch-status --json` exposes dispatch owner policy and refusal for strict unowned boards.
- `/opt/hermes-webui/api/kanban_bridge.py` imports and `_config_payload()` / `_list_boards_payload()` expose owner fields.
- Dockerfile test gates passed during build:
  - Agent focused tests: 150 expected at the time of this run.
  - WebUI focused tests: 57 expected at the time of this run.

## Moss cutover gate

Before launching the external host-side deploy script, check WebUI health. If `active_runs` or `active_streams` is non-zero, do not self-replace Moss unless the operator explicitly authorizes interruption.

Use a prepared host-side script, not foreground `docker compose up -d moss` from inside Moss. The script must perform one scoped recovery attempt if Docker leaves the container in `Created`, then validate WebUI health, gateway health, and the Kanban dispatch-owner CLI smoke.

## Current repaired SHAs

- Agent: `54fa84fa6925cd5e6d2f5874dff08151ee6e5aec`
- WebUI: `b63ccf8c14c77a4144810e4c5945173148aba713`
