# HDDT Moss (pre-production)

`ops/scripts/hddt-moss.sh` is the fail-closed transaction executor. Production custody is fixed and literal: `/mnt/ssd/appdata/the-ai-crowd-hddt/{bin,release-source,state}`, with operation, authorization, receipt, lock, and outbox state beneath `state`; shared ancestors are not part of the custody contract. Stack inputs are independently fixed at `/mnt/ssd/appdata/the-ai-crowd`. `/mnt/user` aliases, symlinks, non-canonical paths, unsafe ownership/modes, domain overlap, and live mount-source overlap are rejected. Only `HDDT_REHEARSAL=1` with an isolated explicit fixture root may select fake paths or fake Docker.

## Commands

- `prepare --operation-id … --mode followable …` creates the private request/journal; no other mode is accepted.
- `hddt-moss-launcher.sh --operation-id …` is the only production run entrypoint. It validates the exact request, authorization, receipt, source, custody, and installed executor/launcher bytes, then spawns the literal executor argv under `env -i`, `nohup`, and `setsid`.
- `run --operation-id …` is executor-side and requires the bound two-party `runner.launch.json`/`runner.started.json` handshake in production.
- `confirm` / `rollback` publish one serialized control decision.
- `recover` classifies legacy/incomplete/third-state operations before lifecycle and returns sanitized unresolved without creating state or consuming authorization.
- `hddt-moss-status.sh --operation-id …` is observational and uses fixed `/usr/bin/docker` in production.

The producer and consumer use one shared canonical closure implementation. Receipt, request, authorization, and launch bind independent `source_closure_sha256`, `builder_sha256`, `executor_sha256`, and `launcher_sha256` values. `terminal.json` is the sole success authority; runner exit status or a missing/zero exit record never implies deployment success.

Build and deploy inputs are deliberately separate. Only `ops/scripts/build-moss-all-in-one-candidate.sh` consumes `MOSS_BASE_IMAGE` and `CLASH_ROYALE_BUILD_INPUT_DIR`. Compose deployment selects an already-built candidate with `MOSS_IMAGE_REF`; release validation and `up --no-build` rendering do not receive or require build inputs.

## Validation

Run `ops/tests/run-moss-release-tests.sh`. It dispatches the Lite contract and isolated causal mutant suites before the producer/receipt and legacy T01–T83 suites. All source tests are fake-only and do not use a real Docker socket or production HDDT root.

## Explicitly not production-ready

No production HDDT root, authorization, lifecycle invocation, target mutation, build receipt, or live-channel credential is created by this package. Gate D materialization and Gate E lifecycle remain separate approvals.
