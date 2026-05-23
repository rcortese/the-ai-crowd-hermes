# The AI Crowd Hermes

Public scaffold for running The AI Crowd agents on Hermes Agent with per-agent homes, images, tool inventories, capability examples, and validation gates.

## What this repository is

- A public, reproducible scaffold for Hermes-based agent containers.
- A safe architecture and validation workspace for Moss in the Hermes runtime.
- A template that defines public contracts, examples, and policy boundaries.

## What this repository is not

- It is not a private deployment checkout.
- It is not full OpenClaw runtime parity.
- It does not contain credentials, provider/OAuth state, session history, private memory, real hostnames, private network details, SSH keys, Docker socket mounts, or reverse-proxy credentials.

## Current status

- MVP stack: `moss` is the default-enabled scaffold service; this is not a production-live/cutover declaration. `richmond` and `the-elders` remain profile-gated.
- Moss public architecture, contracts, capability/mount policy, schemas, examples, and validation scripts are present.
- Public hardening covers digest-pinned base images, backup/restore contracts, release process, health checks, and drift detection; live cutover still requires private deployment smoke, backup evidence, and explicit approval.
- Deployment-specific DNS, paths, reverse-proxy routes, credentials, provider auth, and per-agent runtime configs live outside this repository.

## Start here

1. Read the documentation index: [`docs/README.md`](docs/README.md).
2. Review the public architecture: [`docs/architecture/system-overview.md`](docs/architecture/system-overview.md).
3. Review deployment posture: [`docs/PRODUCTION.md`](docs/PRODUCTION.md), [`docs/HARDENING.md`](docs/HARDENING.md), and [`docs/VALIDATION.md`](docs/VALIDATION.md).
4. Run the public-safe validation entrypoint:

   ```bash
   ./tests/run-all.sh
   ```

## Layout

```text
ops/
  images/                 # Public Docker image definitions
  manifests/              # Installed-tool inventories and capability examples
  policies/               # Capability, mount, and private-overlay policy
agents/
  moss/                   # Moss home, contracts, wrappers, tests
  richmond/               # Profile-gated ArchiveOps-oriented scaffold
  the-elders/             # Profile-gated packet-only scaffold
schemas/                  # Public JSON schema contracts
examples/                 # Public sample cards/handoffs/review gates
shared/                   # Public shared handoff placeholder
docs/                     # Runbooks, architecture, operations, decisions
tests/                    # Public-safe validation and smoke scripts
```

## Runbooks and indexes

- Documentation index: [`docs/README.md`](docs/README.md)
- Production MVP template: [`docs/PRODUCTION.md`](docs/PRODUCTION.md)
- Rollback template: [`docs/ROLLBACK.md`](docs/ROLLBACK.md)
- Hardening backlog: [`docs/HARDENING.md`](docs/HARDENING.md)
- Validation checks: [`docs/VALIDATION.md`](docs/VALIDATION.md)
- Backup and restore: [`docs/operations/backup-restore.md`](docs/operations/backup-restore.md)
- Release process: [`docs/operations/release-process.md`](docs/operations/release-process.md)
- Drift detection: [`docs/operations/drift-detection.md`](docs/operations/drift-detection.md)
- Cutover checklist: [`docs/operations/cutover-checklist.md`](docs/operations/cutover-checklist.md)
- Capability lanes: [`docs/operations/capability-lanes.md`](docs/operations/capability-lanes.md)
- Private mount boundary: [`docs/operations/private-mount-boundary.md`](docs/operations/private-mount-boundary.md)
- OpenClaw transition support: [`docs/operations/openclaw-transition.md`](docs/operations/openclaw-transition.md)
- Migration viability: [`docs/migration-viability.md`](docs/migration-viability.md)

## Deploy template

Use a private deployment checkout and provide environment-specific paths, DNS, credentials, environment files, and reverse-proxy configuration outside git. The base `compose.yaml` intentionally does not require `.env` so public validation works from a clean checkout. If a private deployment needs `.env` and a reverse-proxy network, copy `compose.private.example.yaml` to the ignored `compose.private.yaml`, set the deployment-specific external network name, and include both files in Compose commands.

```bash
cd <deployment-checkout>
docker compose config
docker compose up -d --build moss
docker compose ps
```

With a private override:

```bash
docker compose -f compose.yaml -f compose.private.yaml config
docker compose -f compose.yaml -f compose.private.yaml up -d --build moss
```

Optional profiles, not yet production-enabled:

```bash
COMPOSE_PROFILES=richmond docker compose up -d --build richmond
COMPOSE_PROFILES=the-elders docker compose up -d --build the-elders
```

## Important boundaries

`moss` gets a broader ops image, but installed tools do not imply authority. `richmond` gets a constrained ArchiveOps-oriented image. `the-elders` is intentionally packet-only/minimal.

The Hermes dashboard binds inside Docker with `--insecure` for container networking. Production exposure must be handled by private deployment config. Do not add host `ports:`, public DNS, reverse-proxy routes, credentials, SSH keys, Docker socket mounts, or host-control mounts in this scaffold without a separate security review.
