#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  echo "usage: $0 --compose-root DIR --env-file FILE --expected-image-ref sha256:... --expected-rollback-image-ref sha256:..." >&2
  exit 64
}

compose_root=
env_file=
expected_image_ref=
expected_rollback_image_ref=
while (($#)); do
  case "$1" in
    --compose-root) [[ $# -ge 2 ]] || usage; compose_root=$2; shift 2 ;;
    --env-file) [[ $# -ge 2 ]] || usage; env_file=$2; shift 2 ;;
    --expected-image-ref) [[ $# -ge 2 ]] || usage; expected_image_ref=$2; shift 2 ;;
    --expected-rollback-image-ref) [[ $# -ge 2 ]] || usage; expected_rollback_image_ref=$2; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$compose_root" && -n "$env_file" && -n "$expected_image_ref" && -n "$expected_rollback_image_ref" ]] || usage
[[ -f "$compose_root/compose.yaml" && -f "$env_file" ]] || { echo "ERROR: compose root or env file is missing" >&2; exit 66; }
[[ "$expected_image_ref" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "ERROR: expected image ref must be a local immutable sha256 image ID" >&2; exit 64; }
[[ "$expected_rollback_image_ref" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "ERROR: expected rollback ref must be a local immutable sha256 image ID" >&2; exit 64; }
[[ "$expected_image_ref" != "$expected_rollback_image_ref" ]] || { echo "ERROR: candidate and rollback image IDs must differ" >&2; exit 64; }

grep -qx "MOSS_IMAGE_REF=$expected_image_ref" "$env_file" || { echo "ERROR: MOSS_IMAGE_REF does not bind the expected candidate" >&2; exit 65; }
grep -qx "MOSS_ROLLBACK_IMAGE_REF=$expected_rollback_image_ref" "$env_file" || { echo "ERROR: MOSS_ROLLBACK_IMAGE_REF does not bind the expected rollback" >&2; exit 65; }

for image_ref in "$expected_image_ref" "$expected_rollback_image_ref"; do
  local_id=$(docker image inspect "$image_ref" --format '{{.Id}}' 2>/dev/null) || { echo "ERROR: required local image is unavailable: $image_ref" >&2; exit 66; }
  [[ "$local_id" == "$image_ref" ]] || { echo "ERROR: local image identity mismatch for $image_ref: $local_id" >&2; exit 65; }
done

resolved=$(docker compose --project-directory "$compose_root" --env-file "$env_file" -f "$compose_root/compose.yaml" config --format json | jq -er '.services.moss.image')
[[ "$resolved" == "$expected_image_ref" ]] || { echo "ERROR: Compose resolved Moss to '${resolved:-nothing}', expected '$expected_image_ref'" >&2; exit 65; }

printf 'moss-release-binding: PASS candidate=%s rollback=%s\n' "$expected_image_ref" "$expected_rollback_image_ref"
