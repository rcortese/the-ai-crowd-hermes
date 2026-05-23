# Migration viability: OpenClaw -> Hermes per-agent containers

## Verdict

Viable as an incremental migration, not as a one-shot replacement.

The proposed layout is a good direction because it moves tool/runtime boundaries out of an opaque agent config and into inspectable production artifacts:

- per-agent Docker images;
- per-agent Hermes homes;
- per-agent tool manifests;
- shared material explicitly mounted;
- private reverse-proxy access only for selected agents, configured outside this public scaffold.

## What works well

1. **Agent isolation**: Moss, Richmond, and the-elders can have separate homes and images.
2. **Runtime differentiation**: Richmond can have archive/document tooling without Moss-level ops powers.
3. **Versionability**: Compose, image definitions, manifests, and agent instructions can live in `origin/main`.
4. **Operational rollback**: `docker compose down/up` and git revert are straightforward.

## What does not migrate automatically

1. OpenClaw OAuth/model state.
2. OpenClaw per-tool allow/deny enforcement.
3. OpenClaw cron/session/subagent mechanics.
4. lossless-claw/context-mode recall.
5. External messaging channel bindings.
6. Existing session continuity.

## MVP choice

Enable only Moss by default and protect access through private deployment-specific DNS/reverse-proxy configuration. Build Richmond/the-elders images and homes now, but keep them profile-gated until the Moss path proves stable.

## Next hardening steps

1. Decide Hermes model/provider credential strategy.
2. Add explicit auth beyond reverse-proxy authentication if Hermes supports it.
3. Port one automation at a time from OpenClaw cron to Hermes/native/systemd.
4. Add a backup policy for private deployment agent-state directories.
5. Add a tested mount policy before exposing SSH keys or Docker socket to Moss.
