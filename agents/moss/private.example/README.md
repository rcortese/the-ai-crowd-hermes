# Moss private repo template

This public-safe template documents the expected shape of the ignored nested private repo at `agents/moss/private/`.

Do not put real private data in `agents/moss/private.example/`.

## Intended private repo shape

```text
agents/moss/private/
├── README.md
├── standing/
├── memory/
├── operations/
├── corrections/
├── incidents/
├── private-infrastructure/
├── runbooks/
└── indexes/
```

## Rules

- This is for Moss-owned private versionable state only.
- Do not version real `.env`, auth, tokens, provider state, sessions, caches, runtime databases, dumps, or log dumps.
- Do not store Jen, Denholm, Richmond, Roy, or The Elders private state here by default.
- Use a separate private repo when the split rule applies: independent lifecycle, deploy, ownership, risk, or sharing boundary.
- `indexes/` may be generated and should not be treated as source of truth.
