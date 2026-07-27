#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PERSONA="${1:?usage: $0 PERSONA CURRENT_IMAGE CURRENT_IMAGE_ID OUTPUT_TAG}"
CURRENT_TAG="${2:?usage: $0 PERSONA CURRENT_IMAGE CURRENT_IMAGE_ID OUTPUT_TAG}"
EXPECTED_CURRENT_ID="${3:?usage: $0 PERSONA CURRENT_IMAGE CURRENT_IMAGE_ID OUTPUT_TAG}"
TAG="${4:?usage: $0 PERSONA CURRENT_IMAGE CURRENT_IMAGE_ID OUTPUT_TAG}"
case "$PERSONA" in
  moss|roy) ;;
  *) printf 'unsupported all-in-one persona: %s\n' "$PERSONA" >&2; exit 2 ;;
esac
LOCK="$ROOT/ops/manifests/base-images.lock.json"

command -v jq >/dev/null
command -v docker >/dev/null
[[ -z "$(git -C "$ROOT" status --porcelain)" ]] || {
  printf '%s\n' 'refusing dirty source worktree' >&2; exit 1;
}
HERMES_TAG="$(jq -er '.images[] | select(.name == "hermes-agent") | .image' "$LOCK")"
EXPECTED_HERMES_ID="$(jq -er '.images[] | select(.name == "hermes-agent") | .image_id' "$LOCK")"
HERMES_REV="$(jq -er '.images[] | select(.name == "hermes-agent") | .source_revision' "$LOCK")"
[[ "$(docker image inspect "$CURRENT_TAG" --format '{{.Id}}')" == "$EXPECTED_CURRENT_ID" ]] || {
  printf '%s\n' 'current runtime image ID mismatch' >&2; exit 1;
}
[[ "$(docker image inspect "$HERMES_TAG" --format '{{.Id}}')" == "$EXPECTED_HERMES_ID" ]] || {
  printf '%s\n' 'Hermes candidate image ID mismatch' >&2; exit 1;
}
COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
TREE="$(git -C "$ROOT" rev-parse HEAD^{tree})"
CTX="$(mktemp -d "${TMPDIR:-/tmp}/runtime-a2a-overlay.XXXXXX")"
trap 'rm -rf "$CTX"' EXIT
git -C "$ROOT" archive --format=tar "$COMMIT" | tar -xf - -C "$CTX"
docker build --pull=false \
  --file "$CTX/ops/images/Dockerfile.runtime-a2a-overlay" \
  --tag "$TAG" \
  --build-arg "CURRENT_RUNTIME_IMAGE=$CURRENT_TAG" \
  --build-arg "HERMES_AGENT_IMAGE=$HERMES_TAG" \
  --label "the-ai-crowd.persona=$PERSONA" \
  --label "the-ai-crowd.source-commit=$COMMIT" \
  --label "the-ai-crowd.source-tree=$TREE" \
  --label "the-ai-crowd.current-runtime-base-id=$EXPECTED_CURRENT_ID" \
  --label "the-ai-crowd.hermes-base-id=$EXPECTED_HERMES_ID" \
  --label "the-ai-crowd.hermes-source-revision=$HERMES_REV" \
  "$CTX"
docker image inspect "$TAG" --format 'image={{.Id}} persona={{index .Config.Labels "the-ai-crowd.persona"}} source_commit={{index .Config.Labels "the-ai-crowd.source-commit"}} source_tree={{index .Config.Labels "the-ai-crowd.source-tree"}} current_base={{index .Config.Labels "the-ai-crowd.current-runtime-base-id"}} hermes_base={{index .Config.Labels "the-ai-crowd.hermes-base-id"}} hermes_revision={{index .Config.Labels "the-ai-crowd.hermes-source-revision"}}'
