#!/usr/bin/env bash
# Kept at the historical path; intentionally Bash so the source-only runner has
# no Python image/container dependency. It validates the receipt producer shape.
set -Eeuo pipefail
root=${1:?root required}
helper="$root/ops/scripts/build-moss-all-in-one-candidate.sh"
[[ -x $helper ]] || { printf '%s\n' 'missing build helper' >&2; exit 1; }
for token in 'git -C "$ROOT" archive' 'BUILD_RECEIPT_ROOT' 'sha256-' 'candidate_image_id' 'source_revision' 'source_tree' 'MOSS_BASE_IMAGE' 'receipt publication race'; do grep -Fq "$token" "$helper" || { printf 'missing build contract: %s\n' "$token" >&2; exit 1; }; done
printf '%s\n' 'moss-candidate-build-contract: PASS receipt=write-once source-closure=present'
