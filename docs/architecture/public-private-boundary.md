# Public/private boundary

This repository is public by design. It should make The AI Crowd Hermes runtime reproducible without exposing the operator's private deployment.

## Public and versioned

Commit these when useful:

- Dockerfiles, base Compose files, example overrides, and tool manifests.
- Agent public identity and operating contracts.
- Architecture docs, ADRs, schemas, and tests.
- Public-safe runbooks and validation scripts.
- Redacted examples with fake hostnames, fake ids, and placeholder credentials.

## Private and ignored

Keep these out of public git:

- `.env`, `config.yaml`, `auth.json`, OAuth files, tokens, cookies, session state.
- Private hostnames, LAN IPs, filesystem paths, DNS records, reverse-proxy credentials.
- SSH keys, Docker socket exposure decisions, provider/channel credentials.
- Private per-agent repos, private memory, operational history, and local deployment notes.
- Backups, generated caches, logs, and runtime checkpoints.

## Nested private repos

The Hermes public repository remains cohesive at the project root. Public central files under `agents/moss/` remain public/versioned.

For Moss, `agents/moss/private/` is the default nested private Git repository for versionable private state. The public repository must ignore `agents/*/private/`, and `git ls-files agents/moss/private` must return nothing.

Split rule: `agents/moss/private/` is the Moss private root. A subdomain becomes a separate private repository only when it has an independent lifecycle, deploy surface, ownership boundary, risk boundary, or sharing boundary.

Real `.env`, auth files, tokens, OAuth/provider state, sessions, caches, runtime databases, raw dumps, and log dumps are not versioned at all. Private Git is for curated private source-of-truth state, not ephemeral runtime state.

Other agents or domains keep their own private state under their own owner boundaries. Moss does not become the default host for Jen, Denholm, Richmond, Roy, or The Elders private state by filesystem proximity.

## Safe examples

Use placeholders such as:

- `example.internal`
- `/srv/example/the-ai-crowd`
- `PRIVATE_REVERSE_PROXY_NETWORK`
- `<provider-token>`

Do not use real private names, addresses, or paths in examples.

## Publication rule

Before committing or pushing public files, run:

```bash
./tests/release-scan.sh
./tests/validate-schemas.sh
```

The scan is a guardrail, not a guarantee. If a file is private by nature, do not rely on scanning; keep it ignored or move it into a private repo.
