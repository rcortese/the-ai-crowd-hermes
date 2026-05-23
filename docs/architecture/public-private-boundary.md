# Public/private boundary

This repository is public by design. It should make The AI Crowd Hermes runtime reproducible without exposing an operator's private deployment.

## Public and versioned

Commit these when useful:

- Dockerfiles, base Compose files, example overrides, and tool manifests.
- Agent public identity and operating contracts under `agents/public/<agent>/`.
- Architecture docs, ADRs, schemas, and tests.
- Public-safe runbooks and validation scripts.
- Redacted examples with fake hostnames, fake ids, and placeholder credentials.

Each public agent contract should include at least:

```text
agents/public/<agent>/AGENTS.md
agents/public/<agent>/SOUL.md
agents/public/<agent>/README.md
agents/public/<agent>/config.example.yaml
```

Optional public-safe templates live under `agents/public/<agent>/private.example/`.

## Private and ignored

Keep these out of public git:

- `.env`, real config, auth files, OAuth files, tokens, cookies, session state.
- Private hostnames, LAN IPs, filesystem paths, DNS records, reverse-proxy credentials.
- SSH keys, Docker socket exposure decisions, provider/channel credentials.
- Private per-agent repos, private memory, operational history, and local deployment notes.
- Backups, generated caches, logs, and runtime checkpoints.

Private workspaces use ignored slots:

```text
agents/private/<agent>/
```

The public repository must ignore `agents/private/`, and `git ls-files agents/private` must return nothing.

## Runtime state

Runtime state is not public source and not the curated private workspace. Use ignored runtime paths such as:

```text
runtime/<agent>-home/
state/shared/
```

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

The scan is a guardrail, not a guarantee. If a file is private by nature, keep it ignored or move it into a private repo.
