#!/usr/bin/env bash
# Candidate-only deployment runner. It is intentionally inert unless an operator
# supplies --execute; K3 validates source and runner behavior, never production.
set -euo pipefail
usage() { cat <<'EOF'
Usage: deploy-moss-write-safe-root-candidate.sh --commit SHA --phase PHASE [--execute]

Phases: preflight, build, validate, promote.  promote requires an explicit
operator run and is the only phase allowed to recreate moss; it is not used by
K3. All state is written below ops/candidates/write-safe-root-<commit>.
EOF
}
commit= phase= execute=0
while (($#)); do
  case "$1" in
    --commit) commit=${2:?}; shift 2;;
    --phase) phase=${2:?}; shift 2;;
    --execute) execute=1; shift;;
    -h|--help) usage; exit 0;;
    *) usage >&2; exit 2;;
  esac
done
[[ $commit && $phase ]] || { usage >&2; exit 2; }
case "$phase" in preflight|build|validate|promote) ;; *) echo "invalid phase: $phase" >&2; exit 2;; esac
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
state="$repo/ops/candidates/write-safe-root-$commit"
mkdir -p "$state"
printf '%s
' "$commit" >"$state/commit"
if (( ! execute )); then printf 'dry-run %s
' "$phase" >"$state/status"; exit 0; fi
[[ $(git -C "$repo" rev-parse HEAD) == "$commit" ]] || { echo 'commit CAS mismatch' >&2; exit 1; }
docker compose -f "$repo/compose.yaml" config --quiet
case "$phase" in
  preflight) docker compose -f "$repo/compose.yaml" config --format json >"$state/compose.json";;
  build) docker build --tag "the-ai-crowd/moss-all-in-one:write-safe-root-$commit" -f "$repo/ops/images/Dockerfile.moss-all-in-one" "$repo" >"$state/build.log";;
  validate) echo 'candidate validation is performed by K6 only' >&2; exit 1;;
  promote) echo 'promotion requires K7 approval and external guarded invocation' >&2; exit 1;;
esac
