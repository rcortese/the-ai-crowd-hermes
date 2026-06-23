# Handoff — Honcho local lab stack staging

Task: t_c382c974
Date: 2026-05-29
Host: <docker-host> / Unraid
Target path: <stack-root>/honcho-local

## Result

I staged the Honcho local lab stack files at the approved target path, but I did not create, start, recreate, or restart any containers/services.

Reason: the task body requires explicit operator authorization before any container/service creation, recreation, or restart. No separate explicit authorization was present in the card comments/run context. The staged files are ready for the next authorized apply step.

## Files staged on host

- <stack-root>/honcho-local/compose.yaml
- <stack-root>/honcho-local/honcho.env.example
- <stack-root>/honcho-local/litellm.env.example
- <stack-root>/honcho-local/litellm.config.yaml
- <stack-root>/honcho-local/project.env.example
- <stack-root>/honcho-local/honcho-src/ cloned from https://github.com/plastic-labs/honcho.git

Pinned source observed after clone:

- honcho-src HEAD: 85239a69b262c944de3c35900b91c88ba9b84f1a

## Compose shape

Services in the default lab config:

- honcho-api
- honcho-deriver
- honcho-postgres
- honcho-redis
- litellm

Optional profile, not default:

- embeddings-local under profile local-embeddings

Network posture:

- Dedicated compose network only: honcho_local
- No attachment to the-ai-crowd_internal in this stage
- API debug bind is localhost-only: 127.0.0.1:18000:8000
- LiteLLM debug bind is localhost-only: 127.0.0.1:14000:4000
- Postgres and Redis have no host-published ports

Volumes declared:

- honcho_pgdata
- honcho_redis_data
- litellm_token_state
- embedding_model_cache

## Configuration decisions reflected

- Textual provider path: Honcho -> LiteLLM -> chatgpt/ OAuth provider alias honcho-chat-lab.
- Fallback alias present but not active by default: honcho-chat-fallback-deepseek.
- Embeddings separated from chat provider: Honcho expects OpenAI text-embedding-3-small via HONCHO_EMBEDDINGS_API_KEY.
- DREAM_ENABLED=false for first lab.
- Telemetry/Sentry/metrics disabled for first lab.
- Auth remains disabled only for isolated lab: HONCHO_AUTH_USE_AUTH=false.

## Validation performed

Read-only / non-disruptive checks:

1. Verified host access and Docker/Compose availability:
   - hostname: MEDIA
   - Docker server version: 29.4.3
   - Docker Compose version: v2.40.3
2. Verified canonical The AI Crowd path exists:
   - <stack-root>
3. Verified existing external integration network exists but was not used:
   - the-ai-crowd_internal
4. Rendered staged compose with dummy non-secret env files in a temporary directory:
   - docker compose --env-file project.env.render config --quiet: ok
   - rendered default services: honcho-api,honcho-deriver,honcho-postgres,honcho-redis,litellm
5. Verified no Honcho lab runtime objects were created:
   - containers for compose project honcho-local: none
   - networks for compose project honcho-local: none
   - volumes for compose project honcho-local: none
6. Searched staged non-secret files for obvious token patterns:
   - hits: 0

## Commands used

Commands were run from the Kanban workspace and via ssh -F <ssh-config> <host>.

- ssh <host> 'hostname; docker version; docker compose version; test -d <stack-root>; docker network ls ...'
- ssh <host> 'install -d -m 0750 <stack-root>/honcho-local; git clone --depth 1 https://github.com/plastic-labs/honcho.git honcho-src'
- scp compose/config templates to <host>:<stack-root>/honcho-local/
- ssh <host> 'chmod 0640 ...; chown -R 99:100 <stack-root>/honcho-local'
- ssh <host> 'docker compose --env-file project.env.render config --quiet' in /tmp/honcho-local-compose-render with dummy env files
- ssh <host> 'docker ps/docker network/docker volume filters for com.docker.compose.project=honcho-local'

No docker compose up, docker start, docker restart, docker compose down, volume deletion, or container/service lifecycle mutation was run.

## Secrets and credential handling

No real secrets were printed or written by me into the Kanban workspace.

The host target currently has example/template files only for credentials. Before authorized container creation, the operator or an explicitly authorized secret-handling step must create private runtime files at the target path, mode 0600 where applicable:

- .env from project.env.example, with HONCHO_POSTGRES_PASSWORD, LITELLM_MASTER_KEY, HONCHO_EMBEDDINGS_API_KEY, HONCHO_AUTH_USE_AUTH
- honcho.env from honcho.env.example
- litellm.env from litellm.env.example

Credential decisions still needed before actual apply:

1. ChatGPT/Codex OAuth: perform a LiteLLM-compatible device login/token setup for the lab, preferably isolated in litellm_token_state. Do not share Moss's live Codex auth.json unless the operator explicitly accepts the concurrency/refresh risk.
2. Embeddings: choose/provide an operator-approved embeddings key/provider. The staged config assumes OpenAI text-embedding-3-small via HONCHO_EMBEDDINGS_API_KEY.
3. DeepSeek fallback: only populate DEEPSEEK_API_KEY if the fallback path is explicitly selected for validation.

## Next authorized apply command shape

Only after explicit operator authorization and private env files are in place:

```bash
ssh -F <ssh-config> <host> 'cd <stack-root>/honcho-local && docker compose config --quiet && docker compose up -d honcho-postgres honcho-redis litellm honcho-api honcho-deriver'
```

Then validate:

- docker compose ps
- docker compose logs --tail=200 for each service, with secret scan/redaction discipline
- curl http://127.0.0.1:18000/health from <docker-host>
- curl http://127.0.0.1:14000/health/readiness from <docker-host>
- functional harness from t_c186b991 against http://localhost:18000 or from an approved container/network path

Do not attach honcho-api to the-ai-crowd_internal and do not modify Moss/Jen/Denholm honcho.json/.env until a separate cutover/integration card approves it.
