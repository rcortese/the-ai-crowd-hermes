#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PERSONA="${1:?usage: $0 PERSONA IMAGE_TAG}"
TAG="${2:?usage: $0 PERSONA IMAGE_TAG}"
case "$PERSONA" in moss|jen|denholm|roy|richmond|the-elders) ;; *) printf 'unsupported persona: %s\n' "$PERSONA" >&2; exit 2 ;; esac
command -v jq >/dev/null
command -v docker >/dev/null
[[ -z "$(git -C "$ROOT" status --porcelain)" ]] || { printf '%s\n' 'refusing dirty source worktree' >&2; exit 1; }
HERMES_BASE_REBIND_LOCK="${HERMES_BASE_REBIND_LOCK:?set HERMES_BASE_REBIND_LOCK to the admitted fleet rebind lock relative path}"
HERMES_BASE_V3_RECEIPT="${HERMES_BASE_V3_RECEIPT:?set HERMES_BASE_V3_RECEIPT to the admitted Hermes-base-v3 receipt}"
LOCK="$ROOT/$HERMES_BASE_REBIND_LOCK"
V3_LOCK="$ROOT/ops/manifests/hermes-base-v3.lock.json"
"$ROOT/ops/release/fleet_hermes_918b_rebind.py" admit --lock "$LOCK" --v3-lock "$V3_LOCK" --receipt "$HERMES_BASE_V3_RECEIPT" --inspect-command docker
BASE_TAG="$(jq -er '.base.tag' "$LOCK")"
EXPECTED_ID="$(jq -er '.base.local_image_id' "$LOCK")"
HERMES_REV="$(jq -er '.base.source.commit' "$LOCK")"
HERMES_TREE="$(jq -er '.base.source.tree' "$LOCK")"
HERMES_ARCHIVE_SHA256="$(jq -er '.base.source.archive_sha256' "$LOCK")"
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
