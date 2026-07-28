# HDDT Moss (pre-production)

For a semantic overview of the problem, behavior change, validation, and activation boundary, see [Moss Compose rollback — semantic overview](moss-compose-rollback.md).

`ops/scripts/hddt-moss.sh` is the fail-closed transaction executor. Production custody is fixed and literal: `/mnt/ssd/appdata/the-ai-crowd-hddt/{bin,release-source,state}`, with operation, authorization, receipt, lock, retention, and outbox state beneath `state`; shared ancestors are not part of the custody contract. Stack inputs are independently fixed at `/mnt/ssd/appdata/the-ai-crowd`. `/mnt/user` aliases, symlinks, non-canonical paths, unsafe ownership/modes, domain overlap, and live mount-source overlap are rejected. Only `HDDT_REHEARSAL=1` with an isolated explicit fixture root may select fake paths or fake Docker.

## Commands

- `prepare --operation-id … --mode followable …` creates the private request/journal; no other mode is accepted.
- `hddt-moss-launcher.sh --operation-id …` is the only production run entrypoint. It validates the exact request, authorization, receipt, source, custody, and installed executor/launcher bytes, then spawns the literal executor argv under `env -i`, `nohup`, and `setsid`.
- `run --operation-id …` is executor-side and requires the bound two-party `runner.launch.json`/`runner.started.json` handshake in production.
- `confirm` / `rollback` publish one serialized control decision.
- `recover` classifies legacy/incomplete/third-state operations before lifecycle and returns sanitized unresolved without creating state or consuming authorization.
- `hddt-moss-status.sh --operation-id …` is observational and uses fixed `/usr/bin/docker` in production.

The producer and consumer use one shared canonical closure implementation. Receipt, request, authorization, and launch bind independent `source_closure_sha256`, `builder_sha256`, `executor_sha256`, and `launcher_sha256` values. `terminal.json` is the sole success authority; runner exit status or a missing/zero exit record never implies deployment success.

Build and deploy inputs are deliberately separate. Only `ops/scripts/build-moss-all-in-one-candidate.sh` consumes `MOSS_BASE_IMAGE` and the hash-verified private `CLASH_ROYALE_BUILD_INPUT_DIR`. Compose deployment selects an already-built candidate with `MOSS_IMAGE_REF`; release validation and `up --no-build` rendering do not receive or require build inputs.

## Sealed Compose transaction

`prepare` copies two independent input sets into private staging before it promotes the operation:

- `rollback-inputs/`: the active pre-mutation `compose.yaml`, `.env`, `env/fleet.env`, `env/moss-webui.env`, and `env/roy.env`;
- `candidate-inputs/`: the candidate checkout's `compose.yaml` plus byte-identical active env inputs required to render the complete Compose model.

The executor hashes inputs before and after capture, rejects drift or symlinks, and renders from inside each sealed input directory with an empty environment, `--no-path-resolution`, and JSON output. It then normalizes each render to the deploy unit only:

- `services.moss`;
- networks, named volumes, configs, and secrets referenced by Moss.

The resulting `candidate.rendered.json` and `rollback.rendered.json` must contain no `build`, unresolved interpolation, env-file/staging references, missing resource definitions, other personas, or project-name leakage. Apply and rollback use only the corresponding sealed render with `up -d --no-build --no-deps --force-recreate moss`; neither path inherits the current live `compose.yaml`.

A successful candidate or rollback proof requires all of the following:

- Moss is running and healthy with `RestartCount=0` and expected immutable image/container identity;
- the five out-of-scope containers (Jen, Denholm, Roy, Richmond, and The Elders) retain their captured identity, image, start time, status, health, and restart count;
- the bounded native A2A probe passes;
- the terminal state and outbox are durably recorded in order.

Failures are explicit (`ROLLED_BACK`, `ROLLBACK_FAILED`, or unresolved recovery states); rollback errors are never suppressed. Terminal operations receive a private `retention.json` request and are automatically pruned only after the validated retention window (1–90 days). Active or non-terminal operations are never retention candidates.

`bootstrap-hddt-moss-root.sh` also installs the versioned `ops/cron/the-ai-crowd-hddt-retention.cron` manifest into Unraid's persistent Dynamix cron directory, reloads cron through `update_cron`, and reconciles the same bytes on every idempotent bootstrap. The public source contains no preselected release revision, tree, candidate image, receipt path, or receipt hash: every one of those bindings is required explicitly from the separately reviewed build/installation packet. Missing or malformed bindings fail before staging. For a new root, the bootstrap activates the scheduler from the validated private stage before atomically promoting that stage; activation failure restores the prior scheduler state and leaves no deployable root. Existing-root reconciliation similarly snapshots and restores prior scheduler bytes when durability sync, cron activation, or post-activation readback fails; every restoration mutation, restore sync, and cron reload is guarded, with unresolved restoration reported as integrity failure 74. The hourly job invokes only `hddt-moss.sh prune` under a scheduler lock; `prune` refuses arguments, production overrides, missing/non-canonical custody, and performs no lifecycle. Thus expiry does not depend on a later deployment command. A symlinked scheduler target or failed/uncertain cron rollback fails the bootstrap gate.

## Validation

Run `ops/tests/run-moss-release-tests.sh`. It dispatches the Lite contracts, exact closure and runner-completeness checks, fake-first T01–T87 matrix, sealed structural rollback cases T84–T87, adapter/recovery suites, and the causal mutation ledger. The current mutation contract requires 37 semantic RED results, including staged-source cleanliness, candidate/rollback separation, path-stable render, render cwd, retention, peer invariance, and A2A proof.

A real read-only render validation may use `docker compose config --no-path-resolution --format json` against private copies of the active env inputs. It must not run `up`, `create`, `restart`, `stop`, or `down`; reread all six container identities and start times afterwards. Do not publish rendered JSON because it contains expanded environment values. Retain only sanitized structural projections and hashes.

## Explicitly not production-ready

This source package creates no production HDDT root, authorization, lifecycle invocation, target mutation, build receipt, or live-channel credential. A build/smoke authorization and a later lifecycle authorization remain separate gates. Production lifecycle is forbidden until streams have drained and been rechecked, and it requires new explicit operator approval.
