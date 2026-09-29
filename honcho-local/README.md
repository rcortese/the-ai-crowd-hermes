# Honcho local lab

Optional Compose stack (Honcho API + deriver, Postgres/pgvector, Redis, LiteLLM) for trying Honcho memory next to The AI Crowd. It is not part of the main `compose.yaml`.

Prepare private inputs first (all ignored by git):

- `honcho-src/`: a checkout of the Honcho source, used as the build context;
- `honcho.env`, `litellm.env` and `.env`: copy from `honcho.env.example`, `litellm.env.example` and `project.env.example` (mode 0600) and fill in.

Then, from this directory:

```bash
docker compose up -d --build
# add --profile local-embeddings to run a local embeddings server
```

API and LiteLLM listen on loopback only (`127.0.0.1:18000` and `127.0.0.1:14000`).
