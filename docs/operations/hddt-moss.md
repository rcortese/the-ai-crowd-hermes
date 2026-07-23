# HDDT Moss (pre-production)

`ops/scripts/hddt-moss.sh` is the host-side transaction entrypoint. It is fail-closed by default: production invocation requires the approved host-only root and external authorization; only `HDDT_REHEARSAL=1` with an explicit isolated `HDDT_STATE_ROOT` is accepted during pre-production.

## Commands

- `prepare --operation-id … --mode followable only …` creates the private request/journal.
- `run --operation-id …` consumes a fixture authorization only in rehearsal.
- `confirm` / `rollback` publish one serialized control decision.
- `recover` terminalizes an unresolved rehearsal state rather than guessing from a tag.
- `hddt-moss-status.sh --operation-id …` is read-only.

The producer requires `HDDT_SOURCE_BASE_REVISION` as an explicit lowercase 40-hex Git commit. It is provenance for the produced candidate—not authorization: before any Docker invocation it is resolved locally, required to differ from `source_revision`, and required to be an ancestor of it. The request and authorization remain bound to `source_revision`; the hash-bound build receipt carries `source_base_revision` and `base_image`, is copied into the operation, and is revalidated against the authenticated checkout during `prepare` and `run`. For byte-stable re-execution, the receipt's `created_epoch` is the immutable source commit epoch rather than the wall clock of the build invocation.

Build and deploy inputs are deliberately separate. Only `ops/scripts/build-moss-all-in-one-candidate.sh` consumes `MOSS_BASE_IMAGE` and `CLASH_ROYALE_BUILD_INPUT_DIR`. Compose deployment selects an already-built candidate with `MOSS_IMAGE_REF`; release validation and `up --no-build` rendering do not receive or require build inputs. The image fallback in `compose.yaml` is scaffold/development convenience, never a release selector.

## Validation

Run `ops/tests/run-moss-release-tests.sh`. On hosts without Python, the static Python contract test executes in the existing local `python:3.13-alpine` image with `--network none`, a read-only source mount, `--rm`, and an `hddt-rehearsal-*` name.

## Baseline and current pre-production blocker (2026-07-18)

The dedicated worktree was created from `36d014bf91c79f3771665d57a38e3726c558c018` / tree `ee6870e0d1dbf5c2bd248a5a4aff8e97d39ec096`; its current pre-production HEAD is recorded by Git at execution time. The live target was observed read-only as container `3677c00d06d090bcff324e7130912eb434adbf83771d27cb10bf9a9d1cea18f1`, image `sha256:8f4e0833fddfca0ce3b2443557d77240be6fb5c953be1ebbf1bdb83f0c5a2dec`, `healthy`, and `RestartCount=0`.

Candidate build is deliberately blocked: the required checksum-bound private Node input is absent from the approved locations and no reviewed `MOSS_BASE_IMAGE` reference is locally available. No candidate image, HDDT production root, authorization, or Compose lifecycle operation may be created until an external staging authority supplies those exact reviewed inputs.

## Explicitly not production-ready

No production HDDT root, authorization, lifecycle invocation, target mutation, build receipt, or live-channel credential is created by this package. A future promotion must satisfy the reviewed source→candidate receipt, isolated Compose rehearsal, external exact authorization, stream drain/recheck, and separate lifecycle approval.
