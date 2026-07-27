#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CURRENT_TAG="${CURRENT_MOSS_IMAGE:?set CURRENT_MOSS_IMAGE to the reviewed current all-in-one image tag}"
EXPECTED_CURRENT_ID="${CURRENT_MOSS_IMAGE_ID:?set CURRENT_MOSS_IMAGE_ID to its immutable image ID}"
TAG="${1:?usage: $0 IMAGE_TAG}"
LOCK="$ROOT/ops/manifests/base-images.lock.json"

if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
  printf '%s\n' 'refusing dirty source worktree' >&2
  exit 1
fi
HERMES_TAG="$(jq -er '.images[] | select(.name == "hermes-agent") | .image' "$LOCK")"
EXPECTED_HERMES_ID="$(jq -er '.images[] | select(.name == "hermes-agent") | .image_id' "$LOCK")"
HERMES_REV="$(jq -er '.images[] | select(.name == "hermes-agent") | .source_revision' "$LOCK")"
[[ "$(docker image inspect "$CURRENT_TAG" --format '{{.Id}}')" == "$EXPECTED_CURRENT_ID" ]] || {
  printf '%s\n' 'current Moss image ID mismatch' >&2; exit 1;
}
[[ "$(docker image inspect "$HERMES_TAG" --format '{{.Id}}')" == "$EXPECTED_HERMES_ID" ]] || {
  printf '%s\n' 'Hermes candidate image ID mismatch' >&2; exit 1;
}
COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
TREE="$(git -C "$ROOT" rev-parse HEAD^{tree})"
CTX="$(mktemp -d "${TMPDIR:-/tmp}/moss-a2a-overlay.XXXXXX")"
trap 'rm -rf "$CTX"' EXIT
git -C "$ROOT" archive --format=tar "$COMMIT" | tar -xf - -C "$CTX"
docker build --pull=false \
  --file "$CTX/ops/images/Dockerfile.moss-a2a-overlay" \
  --tag "$TAG" \
  --build-arg "CURRENT_MOSS_IMAGE=$CURRENT_TAG" \
  --build-arg "HERMES_AGENT_IMAGE=$HERMES_TAG" \
  --label "the-ai-crowd.source-commit=$COMMIT" \
  --label "the-ai-crowd.source-tree=$TREE" \
  --label "the-ai-crowd.current-moss-base-id=$EXPECTED_CURRENT_ID" \
  --label "the-ai-crowd.hermes-base-id=$EXPECTED_HERMES_ID" \
  --label "the-ai-crowd.hermes-source-revision=$HERMES_REV" \
  "$CTX"
docker image inspect "$TAG" --format 'image={{.Id}} source_commit={{index .Config.Labels "the-ai-crowd.source-commit"}} source_tree={{index .Config.Labels "the-ai-crowd.source-tree"}} current_base={{index .Config.Labels "the-ai-crowd.current-moss-base-id"}} hermes_base={{index .Config.Labels "the-ai-crowd.hermes-base-id"}} hermes_revision={{index .Config.Labels "the-ai-crowd.hermes-source-revision"}}'
