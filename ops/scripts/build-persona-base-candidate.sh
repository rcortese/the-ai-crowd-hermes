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
BASE_TAG="${HERMES_AGENT_IMAGE:?set HERMES_AGENT_IMAGE to the immutable Agent candidate image ID or local tag}"
EXPECTED_ID="${HERMES_AGENT_IMAGE_ID:?set HERMES_AGENT_IMAGE_ID to the immutable Agent candidate sha256 ID}"
BASE_SOURCE_REVISION="${HERMES_AGENT_SOURCE_REVISION:?set HERMES_AGENT_SOURCE_REVISION to the full Agent commit}"
BASE_SOURCE_TREE="${HERMES_AGENT_SOURCE_TREE:?set HERMES_AGENT_SOURCE_TREE to the full Agent tree}"
[[ "$EXPECTED_ID" =~ ^sha256:[0-9a-f]{64}$ ]] || { printf '%s\n' 'invalid HERMES_AGENT_IMAGE_ID' >&2; exit 65; }
[[ "$BASE_SOURCE_REVISION" =~ ^[0-9a-f]{40}$ ]] || { printf '%s\n' 'invalid HERMES_AGENT_SOURCE_REVISION' >&2; exit 65; }
[[ "$BASE_SOURCE_TREE" =~ ^[0-9a-f]{40}$ ]] || { printf '%s\n' 'invalid HERMES_AGENT_SOURCE_TREE' >&2; exit 65; }
ACTUAL_ID="$(docker image inspect "$BASE_TAG" --format '{{.Id}}')"
[[ "$ACTUAL_ID" == "$EXPECTED_ID" ]] || {
  printf 'base image mismatch: expected %s, got %s\n' "$EXPECTED_ID" "$ACTUAL_ID" >&2
  exit 1
}
[[ "$(docker image inspect "$BASE_TAG" --format '{{index .Config.Labels "the-ai-crowd.agent-source-commit"}}')" == "$BASE_SOURCE_REVISION" ]] || { printf '%s\n' 'Agent source revision label mismatch' >&2; exit 65; }
[[ "$(docker image inspect "$BASE_TAG" --format '{{index .Config.Labels "the-ai-crowd.agent-source-tree"}}')" == "$BASE_SOURCE_TREE" ]] || { printf '%s\n' 'Agent source tree label mismatch' >&2; exit 65; }
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
  --label "the-ai-crowd.hermes-base-source-tree=$BASE_SOURCE_TREE" \
  "$CTX"
docker image inspect "$TAG" --format 'tag={{index .RepoTags 0}} image={{.Id}} source_commit={{index .Config.Labels "the-ai-crowd.source-commit"}} source_tree={{index .Config.Labels "the-ai-crowd.source-tree"}} hermes_base={{index .Config.Labels "the-ai-crowd.hermes-base-id"}} hermes_base_source={{index .Config.Labels "the-ai-crowd.hermes-base-source-revision"}} hermes_base_tree={{index .Config.Labels "the-ai-crowd.hermes-base-source-tree"}}'
