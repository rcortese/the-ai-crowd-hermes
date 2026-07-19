#!/usr/bin/env bash
set -Eeuo pipefail
usage() { echo "usage: $0 --compose-root DIR --env-file FILE --expected-image-ref sha256:... --expected-rollback-image-ref sha256:... --moss-base-image REF" >&2; exit 64; }
compose_root= env_file= expected_image_ref= expected_rollback_image_ref= moss_base_image=
while (($#)); do case "$1" in
 --compose-root|--env-file|--expected-image-ref|--expected-rollback-image-ref|--moss-base-image) [[ $# -gt 1 ]] || usage; case "$1" in --compose-root) compose_root=$2;; --env-file) env_file=$2;; --expected-image-ref) expected_image_ref=$2;; --expected-rollback-image-ref) expected_rollback_image_ref=$2;; --moss-base-image) moss_base_image=$2;; esac; shift 2;; *) usage;; esac; done
[[ -f "$compose_root/compose.yaml" && -f "$env_file" && -n "$moss_base_image" ]] || { echo 'ERROR: compose inputs missing' >&2; exit 66; }
for image in "$expected_image_ref" "$expected_rollback_image_ref"; do [[ "$image" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo 'ERROR: expected image ref must be immutable sha256' >&2; exit 64; }; local_id=$(docker image inspect "$image" --format '{{.Id}}' 2>/dev/null) || { echo "ERROR: required local image is unavailable: $image" >&2; exit 66; }; [[ "$local_id" == "$image" ]] || { echo "ERROR: local image identity mismatch: $local_id" >&2; exit 65; }; done
[[ "$expected_image_ref" != "$expected_rollback_image_ref" ]] || { echo 'ERROR: candidate and rollback IDs must differ' >&2; exit 64; }
render() { env -i HOME=/root PATH="$PATH" MOSS_BASE_IMAGE="$moss_base_image" MOSS_IMAGE_REF="$1" docker compose --project-directory "$compose_root" --env-file "$env_file" -f "$compose_root/compose.yaml" config --format json | jq -er '.services.moss.image'; }
for image in "$expected_image_ref" "$expected_rollback_image_ref"; do resolved=$(render "$image") || exit $?; [[ "$resolved" == "$image" ]] || { echo "ERROR: Compose resolved Moss to ${resolved:-nothing}, expected $image" >&2; exit 65; }; done
printf 'moss-release-binding: PASS candidate=%s rollback=%s\n' "$expected_image_ref" "$expected_rollback_image_ref"
