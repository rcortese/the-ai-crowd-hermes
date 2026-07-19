# HDDT Moss (pre-production)

`ops/scripts/hddt-moss.sh` is the host-side transaction entrypoint. It is fail-closed by default: production invocation requires the approved host-only root and external authorization; only `HDDT_REHEARSAL=1` with an explicit isolated `HDDT_STATE_ROOT` is accepted during pre-production.

## Commands

- `prepare --operation-id … --mode automatic|followable …` creates the private request/journal.
- `run --operation-id …` consumes a fixture authorization only in rehearsal.
- `confirm` / `rollback` publish one serialized control decision.
- `recover` terminalizes an unresolved rehearsal state rather than guessing from a tag.
- `hddt-moss-status.sh --operation-id …` is read-only.

The Compose selector is `MOSS_IMAGE_REF`; it must be a canonical local `sha256:` image ID. The ordinary tag fallback remains for non-HDDT flows. `validate-moss-release-binding.sh` renders both candidate and rollback under `env -i` and rejects image mismatch.

## Validation

Run `ops/tests/run-moss-release-tests.sh`. On hosts without Python, the static Python contract test executes in the existing local `python:3.13-alpine` image with `--network none`, a read-only source mount, `--rm`, and an `hddt-rehearsal-*` name.

## Explicitly not production-ready

No production HDDT root, authorization, lifecycle invocation, target mutation, build receipt, or live-channel credential is created by this package. A future promotion must satisfy the reviewed source→candidate receipt, isolated Compose rehearsal, external exact authorization, stream drain/recheck, and separate lifecycle approval.
