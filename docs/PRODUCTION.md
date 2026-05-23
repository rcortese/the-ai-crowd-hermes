# Production MVP template

## Scope

This repository is a production **template** for Hermes under The AI Crowd. It is not a full OpenClaw migration and does not include environment-specific deployment details.

Currently enabled by default:

- `moss` only.

Profile-gated / not started by default:

- `richmond`
- `the-elders`

## Private deployment data

Keep these outside git:

- deployment hostnames and DNS records;
- LAN hostnames/IPs and filesystem paths;
- reverse-proxy virtual hosts, route files, and credentials;
- provider credentials, OAuth state, and session state;
- backup destinations and operator contact details.

Recommended pattern:

```text
<private-deploy-root>/
  .env
  ops/secrets/
  local-reverse-proxy-config/
  nested-agent-workspaces/
  agents/*/config.yaml
```

## Required reverse-proxy posture

The Hermes dashboard is started with `--insecure` because it binds inside Docker on `0.0.0.0`. This is acceptable only when all of the following remain true:

1. The service is not published with a host `ports:` binding.
2. The service is reachable only on intended private Docker networks.
3. TLS and authentication are enforced by private reverse-proxy config before traffic reaches the stable private upstream `hermes:9119`.
4. Public DNS is not used unless a separate security review explicitly approves it.
5. Hermes model/provider credentials are configured inside the private Hermes home or secret files, not committed to git.

Private reverse-proxy route source-of-truth belongs in private deployment notes. This public template only documents the expected upstream alias and security posture.

## Deploy/update

Set the runtime UID/GID to the deployment checkout owner before starting services. This prevents Hermes from writing bind-mounted files as root or the image's internal user.

```bash
cd <deployment-checkout>
cp .env.example .env  # if .env does not already exist
printf 'HERMES_UID=%s\nHERMES_GID=%s\n' "$(id -u)" "$(id -g)" >> .env
docker compose config
docker compose up -d --build moss
docker compose ps
```

The base `compose.yaml` intentionally does not require `.env` so public validation works from a clean checkout. If the deployment needs private environment files or a private reverse-proxy network, copy `compose.private.example.yaml` to ignored `compose.private.yaml`, set the deployment-specific external network name, and include both files. The private override adds the deployment `.env` file and provides the stable upstream alias `hermes:9119` for the Moss dashboard service:

```bash
docker compose -f compose.yaml -f compose.private.yaml config
docker compose -f compose.yaml -f compose.private.yaml up -d --build moss
```

## Permission repair

If an earlier container run already created files owned by root or another container UID in a bind-mounted agent home, repair the deployment checkout once from the host:

```bash
sudo chown -R "$(id -u):$(id -g)" agents/moss shared
```

Then recreate the service with `HERMES_UID`/`HERMES_GID` set as above. Do not use recursive `chown` on unrelated private mounts or project repositories without first checking their intended owner.

## Validation

Run public-safe checks first:

```bash
./tests/run-all.sh
```

Run smoke deploy only where Docker access is authorized:

```bash
./tests/smoke-deploy.sh
```

`smoke-deploy` exits `2` with `smoke_deploy_blocked` when Docker access is unavailable. It exits `0` with `smoke_deploy_ok` only after Moss starts and the dashboard responds inside the container.

## Smoke tests through private proxy

From the private reverse-proxy network, verify the proxy can reach the dashboard service:

```bash
# Replace <proxy-container> with the private deployment's proxy container.
docker exec <proxy-container> sh -lc 'wget -qO- --timeout=5 http://hermes:9119/ | head -c 120'
```

From a client on the intended private network, verify:

- unauthenticated requests are blocked;
- authenticated requests reach the Hermes dashboard;
- requests from unintended networks are blocked.

## What is intentionally not migrated yet

- OpenClaw OAuth/provider state.
- OpenClaw cron jobs.
- External messaging channel bindings.
- lossless-claw/context-mode memory.
- Existing OpenClaw session continuity.
- Docker socket / private SSH key mounts for Moss.

## Image reproducibility note

The Dockerfiles use the digest-pinned default recorded in `ops/manifests/base-images.lock.json` through `ARG HERMES_AGENT_IMAGE`. Before changing the digest, follow `docs/operations/release-process.md`, run validation, and record the deployed digest in private deployment notes.
