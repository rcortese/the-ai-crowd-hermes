#!/usr/bin/env bash
set -euo pipefail

# Build from an exported clean commit and a hash-pinned private Node input.
ROOT="$(git rev-parse --show-toplevel)"
COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
INPUT_DIR="${CLASH_ROYALE_BUILD_INPUT_DIR:?set CLASH_ROYALE_BUILD_INPUT_DIR to the controlled private Node input directory}"
TAG="${1:?usage: $0 IMAGE_TAG}"
MANIFEST_REL="ops/build-inputs/moss-clash-royale-war-bot.sha256"

if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
  printf '%s\n' 'refusing dirty source worktree' >&2
  exit 1
fi
for name in package.json package-lock.json; do
  test -f "$INPUT_DIR/$name" || { printf 'missing private build input: %s\n' "$name" >&2; exit 1; }
done

CTX="$(mktemp -d "${TMPDIR:-/tmp}/moss-release-context.XXXXXX")"
trap 'rm -rf "$CTX"' EXIT
git -C "$ROOT" archive --format=tar "$COMMIT" | tar -xf - -C "$CTX"
(
  cd "$INPUT_DIR"
  sha256sum -c "$CTX/$MANIFEST_REL"
)
docker build --pull=false \
  --build-context "clash_royale_build_input=$INPUT_DIR" \
  --file "$CTX/ops/images/Dockerfile.moss-all-in-one" \
  --tag "$TAG" \
  "$CTX"
docker image inspect "$TAG" --format 'tag={{index .RepoTags 0}} image={{.Id}} created={{.Created}}'