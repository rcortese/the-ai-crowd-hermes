# Hermes-base v3 source packaging contract

Status: source-only candidate. This repository change **does not authorize or perform an actual build**, image load, tag, registry operation, or runtime/Compose change.

## Locked source input

`ops/manifests/hermes-base-v3.lock.json` binds the only permitted Hermes input to commit `918b36785653ec291806558e30b302b8cad10777`, tree `817966c265522f8a7ae07473284451e17f1e683a`, and the `git archive --format=tar --prefix=hermes-agent/` stream SHA-256 `8a26e82ce96b4b5429d0321e19ddb0b01bed9d5925ab2a0ecc89e9201bfe6aee`, 166256640 bytes. It also binds the only final image tag to `the-ai-crowd/hermes-base:918b36785653`.

The source-only lock intentionally leaves `image.final_image_id` and `receipt` `null`. Both locked image tags are repository-qualified, use strict tag grammar, and must differ. The final tag is fixed in source; a separately authorized host execution can only write its receipt and image ID evidence, not substitute a tag.

## Contract and executor

The stdlib contract rejects unrecognized/missing fields, non-exact archive binding, and incomplete receipts, and malformed or duplicate image archives. OCI normalization removes **only** `Config.Volumes["/opt/data"]` and fails if any residual volume remains. Image-tar normalization applies the equivalent `config.Volumes` deletion, preserves all non-config/manifest members, and assigns only the supplied final tag. Receipts include the loaded post-normalization Config projection, whose canonical hash is recomputed during verification.

`ops/scripts/build-hermes-base-v3.sh --receipt RECEIPT.json` is a controlled host executor and was **not run** for this source change. It consumes the final tag only from the validated lock: callers cannot substitute it. It requires a clean locked source worktree, verifies the archive, and builds from that lock-bound archive with `--network=default` so the Dockerfile can retrieve its pinned apt/npm dependencies; `--pull=false` prevents a base-image refresh. Archive and provenance binding remain unchanged. It then adds provenance labels, retains a distinct pre-normalization tag, normalizes into the locked final tag, writes/verifies the receipt, and performs a separate no-network (`--network=none`), read-only, zero-mount smoke with only ephemeral `/tmp` tmpfs.

No persona rebind is included. `ops/manifests/base-images.lock.json` is not an input to this contract.
