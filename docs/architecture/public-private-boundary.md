# Public/private boundary

This repository is public by design. It should make The AI Crowd Hermes runtime reproducible without exposing an operator's private deployment.

## Public and versioned

Commit these when useful:

- Deployment-agnostic Compose examples, example overrides, and capability manifests. Environment-specific Dockerfiles and fleet image/build closures are private deployment source, not part of this scaffold.
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

Before committing public files, run the offline suite against the working tree:

```bash
./tests/run-all.sh
```

Before pushing, also run the committed archive and all-heads/tags history gate:

```bash
python3 tests/privacy_guard.py --mode all
```

The offline suite alone does not certify committed history. The scanner is a guardrail, not a guarantee; if a file is private by nature, move its source into the appropriate private repository. Ignored local slots do not establish durable versioning. Public source publication does not install, build, activate or authorize a deployment. Hosting-service PR refs/caches and external copies are outside this local gate.
