# Hermes-base v3 source packaging contract

Status: source-only candidate. This repository change **does not authorize or perform an actual build**, image load, tag, registry operation, or runtime/Compose change.

## Locked source input

`ops/manifests/hermes-base-v3.lock.json` binds the only permitted Hermes input to commit `918b36785653ec291806558e30b302b8cad10777`, tree `817966c265522f8a7ae07473284451e17f1e683a`, and the `git archive --format=tar --prefix=hermes-agent/` stream SHA-256 `8a26e82ce96b4b5429d0321e19ddb0b01bed9d5925ab2a0ecc89e9201bfe6aee`, 166256640 bytes.

The source-only lock intentionally leaves `image.final_tag`, `image.final_image_id`, and `receipt` `null`. The repository-qualified locked `image.pre_normalization_tag` is authoritative custody. Final tags must use the same repository and strict tag grammar. They are unavailable until a separately authorized host execution writes a receipt.

## Contract and executor

The stdlib contract rejects unrecognized/missing fields, non-exact archive binding, and incomplete receipts, and malformed or duplicate image archives. OCI normalization removes **only** `Config.Volumes["/opt/data"]` and fails if any residual volume remains. Image-tar normalization applies the equivalent `config.Volumes` deletion, preserves all non-config/manifest members, and assigns only the supplied final tag. Receipts include the loaded post-normalization Config projection, whose canonical hash is recomputed during verification.

`ops/scripts/build-hermes-base-v3.sh --final-tag the-ai-crowd/hermes-base:TAG --receipt RECEIPT.json` is a controlled host executor and was **not run** for this source change. It requires a clean locked source worktree, verifies the archive, builds from that archive only with `--network=none`, adds provenance labels, retains a distinct pre-normalization tag, normalizes before final-tag custody, writes/verifies the receipt, then uses a no-network, read-only, zero-mount smoke (with only ephemeral `/tmp` tmpfs).

No persona rebind is included. `ops/manifests/base-images.lock.json` is not an input to this contract.
