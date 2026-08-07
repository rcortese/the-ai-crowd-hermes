#!/usr/bin/env bash
# Build source-bound, non-activating A2A overlays for Moss and Denholm.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ $# -ne 6 ]]; then
  printf '%s\n' "usage: $0 MOSS_IMAGE MOSS_IMAGE_ID DENHOLM_IMAGE DENHOLM_IMAGE_ID MOSS_TAG DENHOLM_TAG" >&2
  exit 2
fi
MOSS_IMAGE=$1
MOSS_IMAGE_ID=$2
DENHOLM_IMAGE=$3
DENHOLM_IMAGE_ID=$4
MOSS_TAG=$5
DENHOLM_TAG=$6
A2A_TOOLS_SHA256=68e9c9f9b01fc9a22274f36412440839a03436e7cacdcf8751a524b15e187cb0

command -v docker >/dev/null
[[ -z "$(git -C "$ROOT" status --porcelain)" ]] || { printf '%s\n' 'refusing dirty candidate worktree' >&2; exit 1; }
[[ "$(docker image inspect "$MOSS_IMAGE" --format '{{.Id}}')" == "$MOSS_IMAGE_ID" ]] || { printf '%s\n' 'Moss base image ID mismatch' >&2; exit 1; }
[[ "$(docker image inspect "$DENHOLM_IMAGE" --format '{{.Id}}')" == "$DENHOLM_IMAGE_ID" ]] || { printf '%s\n' 'Denholm base image ID mismatch' >&2; exit 1; }

COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
TREE="$(git -C "$ROOT" rev-parse HEAD^{tree})"
CTX="$(mktemp -d "${TMPDIR:-/tmp}/a2a-moss-denholm.XXXXXX")"
trap 'rm -rf "$CTX"' EXIT
git -C "$ROOT" archive --format=tar "$COMMIT" | tar -xf - -C "$CTX"

build_one() {
  local persona=$1 base=$2 tag=$3
  docker build --pull=false \
    --file "$CTX/ops/images/Dockerfile.runtime-a2a-moss-denholm" \
    --tag "$tag" \
    --build-arg "CURRENT_RUNTIME_IMAGE=$base" \
    --build-arg "A2A_TOOLS_SHA256=$A2A_TOOLS_SHA256" \
    --label "the-ai-crowd.persona=$persona" \
    --label "the-ai-crowd.source-commit=$COMMIT" \
    --label "the-ai-crowd.source-tree=$TREE" \
    --label "the-ai-crowd.a2a-topology=moss-to-denholm" \
    --label "the-ai-crowd.a2a-tools-preimage-sha256=$A2A_TOOLS_SHA256" \
    "$CTX"
  docker image inspect "$tag" --format 'image={{.Id}} persona={{index .Config.Labels "the-ai-crowd.persona"}} source_commit={{index .Config.Labels "the-ai-crowd.source-commit"}} source_tree={{index .Config.Labels "the-ai-crowd.source-tree"}} topology={{index .Config.Labels "the-ai-crowd.a2a-topology"}}'
}

build_one moss "$MOSS_IMAGE" "$MOSS_TAG"
build_one denholm "$DENHOLM_IMAGE" "$DENHOLM_TAG"
