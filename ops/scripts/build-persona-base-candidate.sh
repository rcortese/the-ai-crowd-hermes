#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PERSONA="${1:?usage: $0 PERSONA IMAGE_TAG}"
TAG="${2:?usage: $0 PERSONA IMAGE_TAG}"
case "$PERSONA" in
  moss|jen|denholm|roy|richmond|the-elders) ;;
  *) printf 'unsupported persona: %s\n' "$PERSONA" >&2; exit 2 ;;
esac

command -v jq >/dev/null
command -v docker >/dev/null
if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
  printf '%s\n' 'refusing dirty source worktree' >&2
  exit 1
fi
PROTECTED_A2A_LOCK="$ROOT/ops/manifests/protected-hermes-a2a-base.lock.json"
# The approved Hermes 74 base already contains the fixed safe A2A transport.
# Every persona consumes it directly; do not construct a runtime overlay.
BASE_TAG="$(jq -er '.protected_base.image' "$PROTECTED_A2A_LOCK")"
EXPECTED_ID="$(jq -er '.protected_base.image_id' "$PROTECTED_A2A_LOCK")"
BASE_SOURCE_REVISION="$(jq -er '.protected_base.source_revision' "$PROTECTED_A2A_LOCK")"
ACTUAL_ID="$(docker image inspect "$BASE_TAG" --format '{{.Id}}')"
[[ "$ACTUAL_ID" == "$EXPECTED_ID" ]] || {
  printf 'base image mismatch: expected %s, got %s\n' "$EXPECTED_ID" "$ACTUAL_ID" >&2
  exit 1
}
COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
TREE="$(git -C "$ROOT" rev-parse HEAD^{tree})"
CTX="$(mktemp -d "${TMPDIR:-/tmp}/persona-base-context.XXXXXX")"
trap 'rm -rf "$CTX"' EXIT
git -C "$ROOT" archive --format=tar "$COMMIT" | tar -xf - -C "$CTX"
docker build --pull=false \
  --file "$CTX/ops/images/Dockerfile.$PERSONA" \
  --tag "$TAG" \
  --build-arg "HERMES_AGENT_IMAGE=$BASE_TAG" \
  --label "the-ai-crowd.source-commit=$COMMIT" \
    --label "org.opencontainers.image.revision=$COMMIT" \
    --label "org.opencontainers.image.source=$(git -C "$ROOT" remote get-url origin)" \
  --label "the-ai-crowd.source-tree=$TREE" \
  --label "the-ai-crowd.hermes-base-id=$EXPECTED_ID" \
  --label "the-ai-crowd.hermes-base-source-revision=$BASE_SOURCE_REVISION" \
  "$CTX"
docker image inspect "$TAG" --format 'tag={{index .RepoTags 0}} image={{.Id}} source_commit={{index .Config.Labels "the-ai-crowd.source-commit"}} source_tree={{index .Config.Labels "the-ai-crowd.source-tree"}} hermes_base={{index .Config.Labels "the-ai-crowd.hermes-base-id"}} hermes_base_source={{index .Config.Labels "the-ai-crowd.hermes-base-source-revision"}}'
