#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PERSONA="${1:?usage: $0 PERSONA IMAGE_TAG}"
TAG="${2:?usage: $0 PERSONA IMAGE_TAG}"
case "$PERSONA" in moss|jen|denholm|roy|richmond|the-elders) ;; *) printf 'unsupported persona: %s\n' "$PERSONA" >&2; exit 2 ;; esac
command -v jq >/dev/null
command -v docker >/dev/null
[[ -z "$(git -C "$ROOT" status --porcelain)" ]] || { printf '%s\n' 'refusing dirty source worktree' >&2; exit 1; }
LOCK="$ROOT/ops/manifests/base-images.lock.json"
HERMES_REV=""; HERMES_TREE=""; HERMES_ARCHIVE_SHA256=""
if [[ -n "${HERMES_BASE_REBIND_LOCK:-}" ]]; then
  LOCK="$ROOT/${HERMES_BASE_REBIND_LOCK}"
  "$ROOT/ops/release/fleet_hermes_918b_rebind.py" --lock "$LOCK" --require-local-image-id
  BASE_TAG="$(jq -er '.base.tag' "$LOCK")"
  EXPECTED_ID="$(jq -er '.base.local_image_id' "$LOCK")"
  HERMES_REV="$(jq -er '.base.source.commit' "$LOCK")"
  HERMES_TREE="$(jq -er '.base.source.tree' "$LOCK")"
  HERMES_ARCHIVE_SHA256="$(jq -er '.base.source.archive_sha256' "$LOCK")"
else
  BASE_TAG="$(jq -er '.images[] | select(.name == "hermes-agent") | .image' "$LOCK")"
  EXPECTED_ID="$(jq -er '.images[] | select(.name == "hermes-agent") | .image_id' "$LOCK")"
fi
ACTUAL_ID="$(docker image inspect "$BASE_TAG" --format '{{.Id}}')"
[[ "$ACTUAL_ID" == "$EXPECTED_ID" ]] || { printf 'base image mismatch: expected %s, got %s\n' "$EXPECTED_ID" "$ACTUAL_ID" >&2; exit 1; }
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
  --label "the-ai-crowd.hermes-base-tag=$BASE_TAG" \
  --label "the-ai-crowd.hermes-source-commit=$HERMES_REV" \
  --label "the-ai-crowd.hermes-source-tree=$HERMES_TREE" \
  --label "the-ai-crowd.hermes-source-archive-sha256=$HERMES_ARCHIVE_SHA256" \
  "$CTX"
docker image inspect "$TAG" --format 'image={{.Id}} hermes_base={{index .Config.Labels "the-ai-crowd.hermes-base-id"}}'
