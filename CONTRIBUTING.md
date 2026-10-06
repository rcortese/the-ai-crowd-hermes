# Contributing

- Read `docs/architecture/public-private-boundary.md` first: nothing private (credentials, real hostnames or paths, memory, deploy receipts) belongs in this repository.
- Run `./tests/run-all.sh` before opening a change. `tests/release-scan.sh` fails on private paths, addresses and secrets.
- Keep `compose.yaml` free of host-specific values: use stack-relative paths (`./...`) and `${VAR:?message}` for anything private, and document the variable in `.env.example`.
- Changing an example image variable is a source change, not deployment. Selecting and activating a real image requires the separate private deployment authorization and review described in `docs/operations/release-process.md`.
- Before publication, run `python3 tests/privacy_guard.py --mode all` against the intended local heads/tags and committed archive. Offline candidate tests alone are insufficient.
