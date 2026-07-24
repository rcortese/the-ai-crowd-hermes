#!/usr/bin/env bash
set -Eeuo pipefail
usage() { echo "usage: $0 --compose-root DIR --env-file FILE --expected-base-image-ref sha256:... --expected-image-ref sha256:... --expected-rollback-image-ref sha256:..." >&2; exit 64; }
compose_root= env_file= expected_base_image_ref= expected_image_ref= expected_rollback_image_ref=
while (($#)); do case "$1" in
 --compose-root|--env-file|--expected-base-image-ref|--expected-image-ref|--expected-rollback-image-ref) [[ $# -gt 1 ]] || usage; case "$1" in --compose-root) compose_root=$2;; --env-file) env_file=$2;; --expected-base-image-ref) expected_base_image_ref=$2;; --expected-image-ref) expected_image_ref=$2;; --expected-rollback-image-ref) expected_rollback_image_ref=$2;; esac; shift 2;; *) usage;; esac; done
[[ -f "$compose_root/compose.yaml" && -f "$env_file" ]] || { echo 'ERROR: compose inputs missing' >&2; exit 66; }
for image in "$expected_base_image_ref" "$expected_image_ref" "$expected_rollback_image_ref"; do [[ "$image" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo 'ERROR: expected image ref must be immutable sha256' >&2; exit 64; }; local_id=$(docker image inspect "$image" --format '{{.Id}}' 2>/dev/null) || { echo "ERROR: required local image is unavailable: $image" >&2; exit 66; }; [[ "$local_id" == "$image" ]] || { echo "ERROR: local image identity mismatch: $local_id" >&2; exit 65; }; done
[[ "$expected_base_image_ref" != "$expected_image_ref" ]] || { echo 'ERROR: candidate image must differ from builder base image' >&2; exit 64; }
[[ "$expected_base_image_ref" != "$expected_rollback_image_ref" ]] || { echo 'ERROR: rollback image must differ from builder base image' >&2; exit 64; }
[[ "$expected_image_ref" != "$expected_rollback_image_ref" ]] || { echo 'ERROR: candidate and rollback IDs must differ' >&2; exit 64; }
for image in "$expected_image_ref" "$expected_rollback_image_ref"; do
  artifact=$(docker image inspect "$image" --format '{{index .Config.Labels "org.the-ai-crowd.artifact"}}' 2>/dev/null) || { echo "ERROR: deployable image metadata unavailable: $image" >&2; exit 65; }
  [[ "$artifact" == moss-all-in-one ]] || { echo "ERROR: image is not a deployable moss-all-in-one artifact: $image" >&2; exit 65; }
done
render() { env -i HOME=/root PATH="$PATH" MOSS_IMAGE_REF="$1" docker compose --project-directory "$compose_root" --env-file "$env_file" -f "$compose_root/compose.yaml" config --format json | jq -er --arg image "$1" '.services.moss | select(.image==$image and (has("build")|not)) | .image'; }
for image in "$expected_image_ref" "$expected_rollback_image_ref"; do
  resolved=$(render "$image") || { echo "ERROR: Compose did not bind Moss to expected immutable image $image" >&2; exit 65; }
  [[ "$resolved" == "$image" ]] || { echo "ERROR: Compose resolved Moss to ${resolved:-nothing}, expected $image" >&2; exit 65; }
done
printf 'moss-release-binding: PASS candidate=%s rollback=%s\n' "$expected_image_ref" "$expected_rollback_image_ref"
