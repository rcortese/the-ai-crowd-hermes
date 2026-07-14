#!/usr/bin/env bash
# Candidate-only deployment runner. It is inert unless an operator supplies
# --execute; the phase order and commit-addressed evidence make promotion safe.
set -Eeuo pipefail

usage() {
  printf '%s\n' \
    'Usage: deploy-moss-write-safe-root-candidate.sh --commit SHA --phase PHASE [--execute]' \
    '' \
    'Phases: preflight, build, validate, promote.' \
    'Dry runs are inert. Only an explicitly executed promote may recreate moss.'
}

die() { printf '%s\n' "$*" >&2; exit 1; }

commit=
phase=
execute=0
while (($#)); do
  case "$1" in
    --commit) (($# >= 2)) || { usage >&2; exit 2; }; commit=$2; shift 2 ;;
    --phase) (($# >= 2)) || { usage >&2; exit 2; }; phase=$2; shift 2 ;;
    --execute) execute=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

[[ -n $commit && -n $phase ]] || { usage >&2; exit 2; }
case "$phase" in preflight|build|validate|promote) ;; *) printf 'invalid phase: %s\n' "$phase" >&2; exit 2 ;; esac

# Do not call git, Docker, or create state for a dry run.
if (( ! execute )); then
  printf 'dry-run %s\n' "$phase"
  exit 0
fi

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
head=$(git -C "$repo" rev-parse HEAD)
resolved_commit=$(git -C "$repo" rev-parse --verify "${commit}^{commit}")
[[ $head == "$resolved_commit" ]] || die 'commit CAS mismatch'

state_root=${MOSS_WRITE_SAFE_ROOT_STATE_ROOT:-"$repo/ops/candidates"}
state="$state_root/write-safe-root-$resolved_commit"
candidate="the-ai-crowd/moss-all-in-one:write-safe-root-$resolved_commit"
production_image="the-ai-crowd/moss-all-in-one:local"
compose=(docker compose -f "$repo/compose.yaml")
mkdir -p "$state"
printf '%s\n' "$resolved_commit" >"$state/commit"
printf '%s\n' "$head" >"$state/head"
printf '%s\n' "$candidate" >"$state/candidate-image"

record_phase() { printf 'commit=%s\nhead=%s\nphase=%s\n' "$resolved_commit" "$head" "$1" >"$state/$1"; }
require_phase() { [[ -s $state/$1 ]] || die "missing CAS-bound $1 evidence"; }

validate_container_image() {
  local expected=$1 observed
  observed=$(docker inspect -f '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}|{{.Image}}' moss)
  [[ $observed == "running|healthy|$expected" ]]
}

mutation_started=0
rollback_image=
rollback() {
  local rollback_rc=0
  [[ -n $rollback_image ]] || return 1
  printf 'rolling_back\n' >"$state/status"
  docker image tag "$rollback_image" "$production_image" || rollback_rc=1
  "${compose[@]}" up -d --no-deps --force-recreate moss || rollback_rc=1
  validate_container_image "$rollback_image" || rollback_rc=1
  if (( rollback_rc )); then
    printf 'rollback_failed\nimage=%s\n' "$rollback_image" >"$state/status"
    return 1
  fi
  printf 'rolled_back\nimage=%s\n' "$rollback_image" >"$state/status"
}

on_exit() {
  local rc=$?
  trap - EXIT INT TERM
  if (( rc != 0 && mutation_started )); then
    rollback || printf 'rollback failed after post-stop error\n' >&2
  fi
  exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

case "$phase" in
  preflight)
    "${compose[@]}" config --quiet
    record_phase preflight
    printf 'preflight_complete\n' >"$state/status"
    ;;
  build)
    require_phase preflight
    docker build --tag "$candidate" -f "$repo/ops/images/Dockerfile.moss-all-in-one" "$repo" >"$state/build.log"
    candidate_image_id=$(docker image inspect -f '{{.Id}}' "$candidate")
    [[ $candidate_image_id =~ ^sha256:[[:xdigit:]]{64}$ ]] || die 'could not record immutable candidate image ID'
    printf '%s\n' "$candidate_image_id" >"$state/candidate-image-id"
    record_phase build
    printf 'build_complete\nimage_id=%s\n' "$candidate_image_id" >"$state/status"
    ;;
  validate)
    require_phase build
    [[ -s $state/candidate-image-id ]] || die 'missing immutable candidate image ID'
    candidate_image_id=$(<"$state/candidate-image-id")
    [[ $candidate_image_id =~ ^sha256:[[:xdigit:]]{64}$ ]] || die 'invalid immutable candidate image ID'
    observed_candidate_image_id=$(docker image inspect -f '{{.Id}}' "$candidate")
    [[ $observed_candidate_image_id == "$candidate_image_id" ]] || die 'candidate image ID changed after build'
    record_phase validate
    printf 'validate_complete\nimage_id=%s\n' "$candidate_image_id" >"$state/status"
    ;;
  promote)
    require_phase validate
    [[ -s $state/candidate-image-id ]] || die 'missing immutable candidate image ID'
    candidate_image_id=$(<"$state/candidate-image-id")
    [[ $candidate_image_id =~ ^sha256:[[:xdigit:]]{64}$ ]] || die 'invalid immutable candidate image ID'
    # Capture and persist the immutable rollback image ID before any stop/recreate call.
    rollback_image=$(docker inspect -f '{{.Image}}' moss)
    [[ $rollback_image =~ ^sha256:[[:xdigit:]]{64}$ ]] || die 'could not record current moss image ID'
    printf '%s\n' "$rollback_image" >"$state/rollback-image"
    docker image tag "$candidate_image_id" "$production_image"
    mutation_started=1
    "${compose[@]}" stop moss
    "${compose[@]}" up -d --no-deps --force-recreate moss
    validate_container_image "$candidate_image_id"
    mutation_started=0
    rm -f "$state/rollback-image"
    record_phase promote
    printf 'promote_complete\nimage_id=%s\n' "$candidate_image_id" >"$state/status"
    ;;
esac
