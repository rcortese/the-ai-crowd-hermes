# Hardening backlog

This is the minimum hardening backlog before expanding Hermes beyond the Moss MVP.

## Access control

- Keep `moss` without host `ports:` bindings.
- Keep dashboard hostnames, credentials, and access rules in private deployment config, not in this public repository.
- Keep the public Compose file on a single canonical deploy path.
- Use private-network DNS and authenticated reverse-proxy rules for access.
- Do not add public DNS or public tunnel exposure without a separate security review.
- Rotate any deployment credentials if they are exposed outside the private deployment environment.

## Runtime containment

- Do not mount Docker socket or private-host SSH keys into Moss until separately reviewed.
- Keep Richmond and the-elders profile-gated until their first dedicated validation.
- Preserve Richmond as archive/document tooling, not host-control tooling.
- Preserve the-elders as packet/read-only tooling.

## Reproducibility

- `the-ai-crowd/hermes-agent` is built from the pinned `rcortese/hermes-agent` fork SHA recorded in `ops/manifests/base-images.lock.json`; Dockerfile `ARG HERMES_AGENT_IMAGE` defaults must match that local fork tag.
- Record the digest used for each production build in private deployment notes.
- Keep `tests/image-pin.sh`, `tests/health-check.sh`, and `tests/drift-detection.sh` in the release gate.
- Run `tests/smoke-deploy.sh` only where Docker access is authorized before any production declaration.

## Data protection

- Do not commit `.env`, agent provider credentials, OAuth state, session state, generated dashboard tokens, production hostnames, LAN details, external provider names, or operator contact details.
- Add the private deployment state directory to the operator's backup procedure after the first credential/provider configuration.
- Treat `agents/*` in the private deployment as stateful application data, not cache.

## Migration sequencing

1. Stabilize Moss dashboard and provider auth.
2. Validate Richmond in profile-gated mode.
3. Validate the-elders in read-only mode.
4. Port one cron/job/channel at a time with rollback evidence.
5. Consider any host-control mounts only after endpoint auth and backup are proven.
