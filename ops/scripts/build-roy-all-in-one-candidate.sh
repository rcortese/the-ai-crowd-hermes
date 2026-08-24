#!/usr/bin/env bash
# Build a Roy all-in-one candidate from immutable, source-bound inputs only.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
git -C "$ROOT" rev-parse --show-toplevel >/dev/null
TAG="${1:?usage: $0 IMAGE_TAG}"
ROY_BASE_IMAGE="${ROY_BASE_IMAGE:-}"
ROY_BASE_CANDIDATE_REF="${ROY_BASE_CANDIDATE_REF:-}"
ROY_WEBUI_REPO="${ROY_WEBUI_REPO:-}"
ROY_WEBUI_REV="${ROY_WEBUI_REV:-}"
ROY_WEBUI_ARCHIVE_SHA256="${ROY_WEBUI_ARCHIVE_SHA256:-}"
BUILD_RECEIPT_ROOT="${BUILD_RECEIPT_ROOT:-}"

fail() { printf '%s\n' "$*" >&2; exit 65; }
[[ $ROY_BASE_IMAGE =~ ^sha256:[0-9a-f]{64}$ ]] || fail 'ROY_BASE_IMAGE must be an immutable local sha256 image ID'
[[ -n $ROY_BASE_CANDIDATE_REF ]] || fail 'ROY_BASE_CANDIDATE_REF must name the required local Roy base candidate'
[[ -n $ROY_WEBUI_REPO ]] || fail 'ROY_WEBUI_REPO must name the source-bound WebUI repository'
[[ $ROY_WEBUI_REV =~ ^[0-9a-f]{40}$ ]] || fail 'ROY_WEBUI_REV must be a full immutable Git revision'
[[ $ROY_WEBUI_ARCHIVE_SHA256 =~ ^[0-9a-f]{64}$ ]] || fail 'ROY_WEBUI_ARCHIVE_SHA256 must be a Git archive SHA-256'
[[ $BUILD_RECEIPT_ROOT == /* && ! -L $BUILD_RECEIPT_ROOT ]] || fail 'BUILD_RECEIPT_ROOT must be an absolute host-only receipt root'
command -v docker >/dev/null || fail 'docker is required for an authorized build'
command -v jq >/dev/null || fail 'jq is required for receipt serialization'

if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
  printf '%s\n' 'refusing dirty source worktree' >&2
  exit 1
fi

COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
TREE="$(git -C "$ROOT" rev-parse HEAD^{tree})"
SOURCE_REMOTE="$(git -C "$ROOT" remote get-url origin)"
# Roy's base candidate is the all-persona stack candidate a2bdd; bind its
# immutable source labels directly so the local image is independently checked.
ROY_BASE_SOURCE_COMMIT="a2bddaf9921c8b8b10f96e188bb61f0a33d9bfc5"
ROY_BASE_SOURCE_TREE="9f483dffbf04b33efb4e7bffd3a0a7247f82e223"
PROTECTED_A2A_LOCK="$ROOT/ops/manifests/protected-hermes-a2a-base.lock.json"
ROY_BASE_HERMES_ID="$(jq -er '.protected_base.image_id' "$PROTECTED_A2A_LOCK")" || fail 'protected Hermes base ID is unavailable'
ROY_BASE_HERMES_SOURCE="$(jq -er '.protected_base.source_revision' "$PROTECTED_A2A_LOCK")" || fail 'protected Hermes base source is unavailable'
CTX="$(mktemp -d "${TMPDIR:-/tmp}/roy-all-in-one-context.XXXXXX")"
trap 'rm -rf "$CTX"' EXIT
git -C "$ROOT" archive --format=tar "$COMMIT" | tar -xf - -C "$CTX"

resolved_base="$(docker image inspect "$ROY_BASE_IMAGE" --format '{{.Id}}')" || fail 'immutable Roy base image is unavailable locally'
[[ $resolved_base == "$ROY_BASE_IMAGE" ]] || fail 'Roy base image ID resolution mismatch'
candidate_ref_id="$(docker image inspect "$ROY_BASE_CANDIDATE_REF" --format '{{.Id}}')" || fail 'Roy base candidate ref is unavailable locally'
[[ $candidate_ref_id == "$ROY_BASE_IMAGE" ]] || fail 'Roy base candidate ref does not resolve to ROY_BASE_IMAGE'
candidate_source_commit="$(docker image inspect "$ROY_BASE_CANDIDATE_REF" --format '{{index .Config.Labels "the-ai-crowd.source-commit"}}')" || fail 'Roy base candidate source commit label is unavailable'
candidate_source_tree="$(docker image inspect "$ROY_BASE_CANDIDATE_REF" --format '{{index .Config.Labels "the-ai-crowd.source-tree"}}')" || fail 'Roy base candidate source tree label is unavailable'
candidate_hermes_id="$(docker image inspect "$ROY_BASE_CANDIDATE_REF" --format '{{index .Config.Labels "the-ai-crowd.hermes-base-id"}}')" || fail 'Roy base candidate Hermes base ID label is unavailable'
candidate_hermes_source="$(docker image inspect "$ROY_BASE_CANDIDATE_REF" --format '{{index .Config.Labels "the-ai-crowd.hermes-base-source-revision"}}')" || fail 'Roy base candidate Hermes base source label is unavailable'
[[ $candidate_source_commit == "$ROY_BASE_SOURCE_COMMIT" && $candidate_source_tree == "$ROY_BASE_SOURCE_TREE" ]] || fail 'Roy base candidate source labels do not match all-persona stack candidate'
[[ $candidate_hermes_id == "$ROY_BASE_HERMES_ID" && $candidate_hermes_source == "$ROY_BASE_HERMES_SOURCE" ]] || fail 'Roy base candidate Hermes base provenance does not match protected base'
# FROM requires a reference. This alias is content-addressed and verified against
# the supplied image ID; it is not an alternate mutable source.
base_alias="the-ai-crowd/roy-build-base:${ROY_BASE_IMAGE#sha256:}"
docker image tag "$ROY_BASE_IMAGE" "$base_alias"
alias_id="$(docker image inspect "$base_alias" --format '{{.Id}}')" || fail 'temporary Roy base alias is unavailable locally'
[[ $alias_id == "$ROY_BASE_IMAGE" ]] || fail 'temporary Roy base alias resolution mismatch'

docker build --pull=false \
  --file "$CTX/ops/images/Dockerfile.roy-all-in-one" \
  --tag "$TAG" \
  --build-arg "ROY_BASE_IMAGE=$base_alias" \
  --build-arg "HERMES_WEBUI_REPO=$ROY_WEBUI_REPO" \
  --build-arg "HERMES_WEBUI_REV=$ROY_WEBUI_REV" \
  --build-arg "HERMES_WEBUI_ARCHIVE_SHA256=$ROY_WEBUI_ARCHIVE_SHA256" \
  --label "the-ai-crowd.source-commit=$COMMIT" \
  --label "the-ai-crowd.source-tree=$TREE" \
  --label "the-ai-crowd.roy-base-id=$ROY_BASE_IMAGE" \
  --label "the-ai-crowd.roy-base-candidate-ref=$ROY_BASE_CANDIDATE_REF" \
  --label "the-ai-crowd.roy-base-source-commit=$candidate_source_commit" \
  --label "the-ai-crowd.roy-base-source-tree=$candidate_source_tree" \
  --label "the-ai-crowd.roy-base-hermes-base-id=$candidate_hermes_id" \
  --label "the-ai-crowd.roy-base-hermes-base-source-revision=$candidate_hermes_source" \
  --label "the-ai-crowd.webui-repository=$ROY_WEBUI_REPO" \
  --label "the-ai-crowd.webui-revision=$ROY_WEBUI_REV" \
  --label "the-ai-crowd.webui-archive-sha256=$ROY_WEBUI_ARCHIVE_SHA256" \
  --label "org.opencontainers.image.revision=$COMMIT" \
  --label "org.opencontainers.image.source=$SOURCE_REMOTE" \
  "$CTX"

image_id="$(docker image inspect "$TAG" --format '{{.Id}}')"
[[ $image_id =~ ^sha256:[0-9a-f]{64}$ ]] || fail 'invalid candidate image ID'
if [[ ! -e $BUILD_RECEIPT_ROOT ]]; then
  parent="$(realpath -e -- "$(dirname "$BUILD_RECEIPT_ROOT")")" || fail 'receipt parent unavailable'
  [[ ! -L $parent ]] || fail 'unsafe receipt parent'
  mkdir -m 700 -- "$BUILD_RECEIPT_ROOT"
fi
[[ $(realpath -e -- "$BUILD_RECEIPT_ROOT") == "$BUILD_RECEIPT_ROOT" && $(stat -c %u "$BUILD_RECEIPT_ROOT") == "$(id -u)" ]] || fail 'receipt root custody mismatch'
chmod 700 "$BUILD_RECEIPT_ROOT"

builder_sha="$(sha256sum "$ROOT/ops/scripts/build-roy-all-in-one-candidate.sh" | cut -d' ' -f1)"
receipt="$BUILD_RECEIPT_ROOT/sha256-${image_id#sha256:}.json"
tmp="$(mktemp "$BUILD_RECEIPT_ROOT/.receipt.XXXXXX")"
jq -ncS \
  --arg status CANDIDATE_BUILT \
  --arg source_commit "$COMMIT" \
  --arg source_tree "$TREE" \
  --arg source_remote "$SOURCE_REMOTE" \
  --arg image_id "$image_id" \
  --arg roy_base_image_id "$ROY_BASE_IMAGE" \
  --arg roy_base_candidate_ref "$ROY_BASE_CANDIDATE_REF" \
  --arg roy_base_source_commit "$candidate_source_commit" \
  --arg roy_base_source_tree "$candidate_source_tree" \
  --arg roy_base_hermes_base_id "$candidate_hermes_id" \
  --arg roy_base_hermes_base_source_revision "$candidate_hermes_source" \
  --arg webui_repository "$ROY_WEBUI_REPO" \
  --arg webui_revision "$ROY_WEBUI_REV" \
  --arg webui_archive_sha256 "$ROY_WEBUI_ARCHIVE_SHA256" \
  --arg builder_sha256 "$builder_sha" \
  '{status:$status,source_commit:$source_commit,source_tree:$source_tree,source_remote:$source_remote,image_id:$image_id,roy_base_image_id:$roy_base_image_id,roy_base_candidate_ref:$roy_base_candidate_ref,roy_base_source_commit:$roy_base_source_commit,roy_base_source_tree:$roy_base_source_tree,roy_base_hermes_base_id:$roy_base_hermes_base_id,roy_base_hermes_base_source_revision:$roy_base_hermes_base_source_revision,webui_repository:$webui_repository,webui_revision:$webui_revision,webui_archive_sha256:$webui_archive_sha256,builder_sha256:$builder_sha256}' >"$tmp"
chmod 600 "$tmp"
sync "$tmp"
if [[ -e $receipt ]]; then
  [[ -f $receipt && ! -L $receipt ]] && cmp -s "$tmp" "$receipt" || { rm -f "$tmp"; fail 'divergent or unsafe build receipt already exists'; }
  rm -f "$tmp"
else
  ln "$tmp" "$receipt" || { rm -f "$tmp"; fail 'receipt publication race'; }
  rm -f "$tmp"
  sync "$BUILD_RECEIPT_ROOT"
fi
printf 'candidate_image=%s build_receipt=%s receipt_sha256=%s\n' "$image_id" "$receipt" "$(sha256sum "$receipt" | cut -d' ' -f1)"
