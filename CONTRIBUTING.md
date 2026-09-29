# Contributing

- Read `docs/architecture/public-private-boundary.md` first: nothing private (credentials, real hostnames or paths, memory, deploy receipts) belongs in this repository.
- Run `./tests/run-all.sh` before opening a change. `tests/release-scan.sh` fails on private paths, addresses and secrets.
- Keep `compose.yaml` free of host-specific values: use stack-relative paths (`./...`) and `${VAR:?message}` for anything private, and document the variable in `.env.example`.
- Changing `services.<name>.image` in `compose.yaml` is a deploy action; follow `docs/operations/release-process.md`.
