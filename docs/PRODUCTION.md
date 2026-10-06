# Private deployment template

The public Compose file is an agnostic example, not the live deployment source. It intentionally provides no release images, user identity, secrets, endpoint routes, external networks or host-control tooling.

1. Review the public source and record its exact commit.
2. Select reviewed compatible images and bind their immutable identities in private release evidence.
3. Supply every image, runtime-root and workspace-root variable listed in `.env.example`. Use existing private directories, never shared persona-private mounts.
4. Configure image startup to consume `/runtime`, `/workspace` and read-only `/contracts`; review UID/GID, credentials, egress, routes, backup and health probes separately.
5. Render the final privately owned Compose configuration and inspect exact images, mount boundaries and network policy.
6. Obtain the target-specific authorization, drain and rollback gates before any lifecycle action.
7. Verify readiness against actual deployed identities and record private evidence.

Source tests and publication approval never imply deployment approval. Runtime smoke, rollback execution and operator procedures belong to private deployment tooling; this repository contains no host runner.
