#!/usr/bin/env bash
# Candidate-only deployment runner. It is inert unless an operator supplies
# --execute; the phase order and commit-addressed evidence make promotion safe.
set -Eeuo pipefail

usage() {
  printf '%s\n' \
    'Usage: deploy-moss-write-safe-root-candidate.sh --commit SHA --phase PHASE [--container CONTAINER] [--execute]' \
    '' \
    'Phases: preflight, build, validate, promote, abort.' \
    'Dry runs are inert. Only an explicitly executed promote may recreate the canonical Moss target.'
}

die() { printf '%s\n' "$*" >&2; exit 1; }

commit=
phase=
container=
execute=0
while (($#)); do
  case "$1" in
    --commit) (($# >= 2)) || { usage >&2; exit 2; }; commit=$2; shift 2 ;;
    --phase) (($# >= 2)) || { usage >&2; exit 2; }; phase=$2; shift 2 ;;
    --container) (($# >= 2)) || { usage >&2; exit 2; }; container=$2; shift 2 ;;
    --execute) execute=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

[[ -n $commit && -n $phase ]] || { usage >&2; exit 2; }
case "$phase" in preflight|build|validate|promote|abort) ;; *) printf 'invalid phase: %s\n' "$phase" >&2; exit 2 ;; esac

# Do not call git, Docker, or create state for a dry run.
if (( ! execute )); then
  printf 'dry-run %s\n' "$phase"
  exit 0
fi

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
canonical_container=${MOSS_CANONICAL_CONTAINER:-the-ai-crowd-moss-1}
container=${container:-$canonical_container}
[[ $container == "$canonical_container" && $container != moss ]] || die 'canonical container target is required'
compose_service=${MOSS_COMPOSE_SERVICE:-moss}
head=$(git -C "$repo" rev-parse HEAD)
resolved_commit=$(git -C "$repo" rev-parse --verify "${commit}^{commit}")
state_root=${MOSS_WRITE_SAFE_ROOT_STATE_ROOT:-"$repo/ops/candidates"}
state="$state_root/write-safe-root-$resolved_commit"
if [[ $head != "$resolved_commit" ]]; then
  if [[ $phase == promote && -s $state/activation-head ]]; then
    die 'activation CAS mismatch: HEAD changed'
  fi
  die 'commit CAS mismatch'
fi

candidate="the-ai-crowd/moss-all-in-one:write-safe-root-$resolved_commit"
base_image="the-ai-crowd/moss:write-safe-root-base-$resolved_commit"
production_image="the-ai-crowd/moss-all-in-one:local"
compose=(docker compose -f "$repo/compose.yaml")
staged_diff_sha256() { git -C "$repo" diff --cached --binary | sha256sum | awk '{print $1}'; }
rendered_compose_sha256() { "${compose[@]}" config | sha256sum | awk '{print $1}'; }
read_live_target() { docker inspect -f '{{.Id}}|{{.Image}}' "$container"; }
record_activation_preflight() {
  local staged_sha live compose_sha live_id live_image observed_candidate
  staged_sha=$(staged_diff_sha256)
  live=$(read_live_target) || die 'canonical container target is missing'
  IFS='|' read -r live_id live_image <<<"$live"
  [[ $live_id =~ ^[[:alnum:]][[:alnum:]._-]*$ && $live_image =~ ^sha256:[[:xdigit:]]{64}$ ]] || die 'canonical container target is invalid'
  compose_sha=$(rendered_compose_sha256)
  [[ $staged_sha =~ ^[[:xdigit:]]{64}$ && $compose_sha =~ ^[[:xdigit:]]{64}$ ]] || die 'could not capture activation CAS evidence'
  printf '%s\n' "$head" >"$state/activation-head"
  printf '%s\n' "$staged_sha" >"$state/activation-staged-diff-sha256"
  printf '%s\n' "$container" >"$state/activation-container"
  printf '%s\n' "$live_id" >"$state/activation-container-id"
  printf '%s\n' "$live_image" >"$state/activation-live-image-id"
  printf '%s\n' "$compose_sha" >"$state/activation-compose-sha256"
  if observed_candidate=$(docker image inspect -f '{{.Id}}' "$candidate" 2>/dev/null); then
    [[ $observed_candidate =~ ^sha256:[[:xdigit:]]{64}$ ]] || die 'could not capture candidate image ID'
    printf '%s\n' "$observed_candidate" >"$state/activation-candidate-image-id"
  else
    rm -f "$state/activation-candidate-image-id"
  fi
}
verify_activation_cas() {
  local expected_head expected_staged expected_container expected_live_id expected_live_image expected_compose expected_candidate live current_staged current_compose current_candidate
  for evidence in activation-head activation-staged-diff-sha256 activation-container activation-container-id activation-live-image-id activation-compose-sha256 activation-candidate-image-id candidate-image-id; do
    [[ -s $state/$evidence ]] || die "missing activation CAS evidence: $evidence"
  done
  expected_head=$(<"$state/activation-head"); expected_staged=$(<"$state/activation-staged-diff-sha256"); expected_container=$(<"$state/activation-container"); expected_live_id=$(<"$state/activation-container-id"); expected_live_image=$(<"$state/activation-live-image-id"); expected_compose=$(<"$state/activation-compose-sha256"); expected_candidate=$(<"$state/activation-candidate-image-id")
  [[ $expected_container == "$canonical_container" && $container == "$expected_container" ]] || die 'canonical container target CAS mismatch'
  [[ $head == "$expected_head" ]] || die 'activation CAS mismatch: HEAD changed'
  current_staged=$(staged_diff_sha256); [[ $current_staged == "$expected_staged" ]] || die 'activation CAS mismatch: staged diff changed'
  live=$(read_live_target) || die 'canonical container target is missing'
  [[ $live == "$expected_live_id|$expected_live_image" ]] || die 'activation CAS mismatch: live target changed'
  current_compose=$(rendered_compose_sha256); [[ $current_compose == "$expected_compose" ]] || die 'activation CAS mismatch: rendered Compose changed'
  current_candidate=$(docker image inspect -f '{{.Id}}' "$candidate") || die 'activation CAS mismatch: candidate missing'
  [[ $current_candidate == "$expected_candidate" && $current_candidate == $(<"$state/candidate-image-id") ]] || die 'activation CAS mismatch: candidate image changed'
}
mkdir -p "$state"
printf '%s\n' "$resolved_commit" >"$state/commit"
printf '%s\n' "$head" >"$state/head"
printf '%s\n' "$candidate" >"$state/candidate-image"

record_phase() { printf 'commit=%s\nhead=%s\nphase=%s\n' "$resolved_commit" "$head" "$1" >"$state/$1"; }
require_phase() { [[ -s $state/$1 ]] || die "missing CAS-bound $1 evidence"; }
remove_build_evidence() { rm -f "$state/build" "$state/candidate-image-id" "$state/validate" "$state/promote" "$state/rollback-image"; }
begin_build_attempt() {
  remove_build_evidence
  printf "build_started\n" >"$state/status"
}

validate_container_image() {
  local expected=$1 observed
  observed=$(docker inspect -f '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}|{{.Image}}' "$container")
  [[ $observed == "running|healthy|$expected" ]]
}

build_candidate() (
  local archive_root context archive expected actual
  archive_root=$(mktemp -d "${TMPDIR:-/tmp}/moss-write-safe-root-context.XXXXXX")
  context="$archive_root/context"
  archive="$archive_root/tracked-tree.tar"
  expected="$archive_root/expected-files"
  actual="$archive_root/archive-files"
  cleanup_candidate_build() {
    local build_rc=$? cleanup_rc=0
    trap - EXIT INT TERM
    docker image rm -f "$base_image" >/dev/null 2>&1 || cleanup_rc=1
    rm -rf "$archive_root" || cleanup_rc=1
    if (( build_rc != 0 )); then
      remove_build_evidence
      printf "build_failed\nexit_code=%s\n" "$build_rc" >"$state/status"
      exit "$build_rc"
    fi
    if (( cleanup_rc != 0 )); then
      remove_build_evidence
      printf "build_cleanup_failed\nexit_code=%s\n" "$cleanup_rc" >"$state/status"
      exit "$cleanup_rc"
    fi
    exit 0
  }
  trap cleanup_candidate_build EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  # The context is populated only from the resolved commit's tracked archive.
  git -C "$repo" archive --format=tar "$resolved_commit" >"$archive"
  git -C "$repo" ls-tree -r --name-only "$resolved_commit" | LC_ALL=C sort -u >"$expected"
  tar -tf "$archive" | grep -v '/$' | LC_ALL=C sort -u >"$actual"
  cmp -s "$expected" "$actual" || die 'tracked archive tree provenance mismatch'
  mkdir -p "$context"
  tar -xf "$archive" -C "$context"

  docker build --tag "$base_image" -f "$context/ops/images/Dockerfile.moss" "$context" >"$state/build-base.log"
  docker build --tag "$candidate" --build-arg "MOSS_BASE_IMAGE=$base_image" -f "$context/ops/images/Dockerfile.moss-all-in-one" "$context" >"$state/build.log"
)

mutation_started=0
rollback_image=
rollback() {
  local rollback_rc=0
  [[ -n $rollback_image ]] || return 1
  printf 'rolling_back\n' >"$state/status"
  docker image tag "$rollback_image" "$production_image" || rollback_rc=1
  "${compose[@]}" up -d --no-deps --force-recreate "$compose_service" || rollback_rc=1
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
    record_activation_preflight
    record_phase preflight
    printf 'preflight_complete\n' >"$state/status"
    ;;
  build)
    require_phase preflight
    begin_build_attempt
    build_candidate
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
  abort)
    # Explicit closeout only: validation deliberately preserves the candidate for K7.
    docker image rm -f "$candidate"
    rm -f "$state/candidate-image-id" "$state/activation-candidate-image-id"
    printf 'abort_complete\n' >"$state/status"
    ;;
  promote)
    require_phase validate
    [[ -s $state/candidate-image-id ]] || die 'missing immutable candidate image ID'
    candidate_image_id=$(<"$state/candidate-image-id")
    [[ $candidate_image_id =~ ^sha256:[[:xdigit:]]{64}$ ]] || die 'invalid immutable candidate image ID'
    # Recheck every source/live/compose/candidate fact before the first mutation.
    verify_activation_cas
    # The CAS-bound live image is the only valid rollback image.
    rollback_image=$(<"$state/activation-live-image-id")
    printf '%s\n' "$rollback_image" >"$state/rollback-image"
    docker image tag "$candidate_image_id" "$production_image"
    mutation_started=1
    "${compose[@]}" stop "$compose_service"
    "${compose[@]}" up -d --no-deps --force-recreate "$compose_service"
    validate_container_image "$candidate_image_id"
    mutation_started=0
    rm -f "$state/rollback-image"
    record_phase promote
    printf 'promote_complete\nimage_id=%s\n' "$candidate_image_id" >"$state/status"
    ;;
esac
