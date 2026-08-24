#!/usr/bin/env bash
# Produce a future, source-bound OCI archive receipt; no implicit build is permitted.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
LOCK="$ROOT/ops/manifests/hermes-base-v4.lock.json"
VALIDATOR="$ROOT/ops/release/hermes_base_v4.py"
EXECUTE=0
AGENT_SOURCE=""
DOCKERFILE=""
ARCHIVE=""
RECEIPT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --execute-build) EXECUTE=1 ;;
    --agent-source) AGENT_SOURCE="${2:?--agent-source requires an Agent checkout}"; shift ;;
    --file) DOCKERFILE="${2:?--file requires a repository-relative Dockerfile}"; shift ;;
    --archive) ARCHIVE="${2:?--archive requires an output path}"; shift ;;
    --receipt) RECEIPT="${2:?--receipt requires an output path}"; shift ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done
python3 -B "$VALIDATOR" --lock "$LOCK" --check-only
if [[ "$EXECUTE" -ne 1 ]]; then
  printf '%s\n' 'source-only plan valid; refusing to build without --execute-build' >&2
  exit 0
fi
[[ -n "$AGENT_SOURCE" && -n "$DOCKERFILE" && -n "$ARCHIVE" && -n "$RECEIPT" ]] || { printf '%s\n' '--execute-build requires --agent-source, --file, --archive, and --receipt' >&2; exit 2; }
[[ "$DOCKERFILE" != /* && "$DOCKERFILE" != *".."* ]] || { printf '%s\n' 'Dockerfile must be repository-relative' >&2; exit 2; }
[[ ! -e "$ARCHIVE" && ! -e "$RECEIPT" ]] || { printf '%s\n' 'refusing to overwrite archive or receipt' >&2; exit 1; }
[[ -z "$(git -C "$ROOT" status --porcelain)" ]] || { printf '%s\n' 'refusing dirty contract worktree' >&2; exit 1; }
source_commit="$(python3 -B -c 'import json,sys; print(json.load(open(sys.argv[1]))["source"]["commit"])' "$LOCK")"
source_tree="$(python3 -B -c 'import json,sys; print(json.load(open(sys.argv[1]))["source"]["tree"])' "$LOCK")"
source_tag="$(python3 -B -c 'import json,sys; print(json.load(open(sys.argv[1]))["source"]["tag"])' "$LOCK")"
[[ -d "$AGENT_SOURCE" ]] || { printf '%s\n' 'Agent source checkout is required' >&2; exit 1; }
[[ "$(git -C "$AGENT_SOURCE" rev-parse "$source_tag^{commit}")" == "$source_commit" ]] || { printf '%s\n' 'Agent source tag does not resolve to locked commit' >&2; exit 1; }
[[ "$(git -C "$AGENT_SOURCE" rev-parse "$source_commit^{tree}")" == "$source_tree" ]] || { printf '%s\n' 'Agent source commit does not resolve to locked tree' >&2; exit 1; }
command -v docker >/dev/null
context="$(mktemp -d "${TMPDIR:-/tmp}/hermes-base-v4.XXXXXX")"
trap 'rm -rf "$context"' EXIT
git -C "$AGENT_SOURCE" archive --format=tar "$source_commit" | tar -xf - -C "$context"
[[ -f "$context/$DOCKERFILE" ]] || { printf 'missing Dockerfile in archive: %s\n' "$DOCKERFILE" >&2; exit 1; }
# The output is an OCI archive; --pull=false prevents mutable base refreshes.
docker buildx build --pull=false --platform linux/amd64 --output "type=oci,dest=$ARCHIVE" --file "$context/$DOCKERFILE" "$context"
printf '{"status":"built-receipt-pending-identity-proof","source_commit":"%s","source_tree":"%s","oci_archive":"%s","platform_manifest_digest":null,"config_digest":null,"local_image_id":null}\n' "$source_commit" "$source_tree" "$ARCHIVE" > "$RECEIPT"
printf '%s\n' "archive produced; receipt intentionally has null identity fields until an independent real-build proof completes"
