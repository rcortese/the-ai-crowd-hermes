#!/usr/bin/env bash
# Candidate-only deployment runner. It is inert unless an operator supplies
# --execute; the phase order and commit-addressed evidence make promotion safe.
set -Eeuo pipefail

usage() {
  printf '%s\n' \
    'Usage: deploy-moss-write-safe-root-candidate.sh --commit SHA --phase PHASE [--container CONTAINER] [--deployment-root /mnt/user/appdata/the-ai-crowd] [--execute]' \
    '' \
    'Phases: preflight, build, validate, promote, abort.' \
    'Dry runs are inert. Only an explicitly executed promote may recreate the canonical Moss target.'
}

die() { printf '%s\n' "$*" >&2; exit 1; }

commit=
phase=
container=
requested_deployment_root=
execute=0
while (($#)); do
  case "$1" in
    --commit) (($# >= 2)) || { usage >&2; exit 2; }; commit=$2; shift 2 ;;
    --phase) (($# >= 2)) || { usage >&2; exit 2; }; phase=$2; shift 2 ;;
    --container) (($# >= 2)) || { usage >&2; exit 2; }; container=$2; shift 2 ;;
    --deployment-root) (($# >= 2)) || { usage >&2; exit 2; }; requested_deployment_root=$2; shift 2 ;;
    --execute) execute=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

[[ -n $commit && -n $phase ]] || { usage >&2; exit 2; }
case "$phase" in preflight|build|validate|promote|abort) ;; *) printf 'invalid phase: %s\n' "$phase" >&2; exit 2 ;; esac

# Compose/lifecycle inputs are a separate trust domain from the reviewed Git
# worktree. This literal path is deliberately neither configurable nor derived
# from the script location, current directory, or environment.
readonly canonical_deployment_root='/mnt/user/appdata/the-ai-crowd'
if [[ -v MOSS_DEPLOYMENT_ROOT ]]; then
  die 'deployment root environment override is not allowed'
fi
if [[ -n $requested_deployment_root && $requested_deployment_root != "$canonical_deployment_root" ]]; then
  die 'canonical deployment root is required'
fi
readonly deployment_root="$canonical_deployment_root"

# Do not call git, Docker, or create state for a dry run.
if (( ! execute )); then
  printf 'dry-run %s\n' "$phase"
  exit 0
fi

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# Production mutation anchors are deliberately literal and cannot be redirected.
if [[ -v MOSS_CANONICAL_CONTAINER || -v MOSS_COMPOSE_SERVICE ]]; then
  die 'canonical target environment overrides are not allowed'
fi
readonly canonical_container='the-ai-crowd-moss-1'
readonly compose_service='moss'
container=${container:-$canonical_container}
[[ $container == "$canonical_container" ]] || die 'canonical container target is required'
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
validate_canonical_deployment_root() {
  [[ -d $deployment_root && ! -L $deployment_root ]] || die 'canonical deployment root is unavailable'
  [[ -f $deployment_root/compose.yaml && ! -L $deployment_root/compose.yaml ]] || die 'canonical Compose input is unavailable'
  [[ -d $deployment_root/env && ! -L $deployment_root/env ]] || die 'canonical Compose environment input is unavailable'
  [[ -f $deployment_root/.env && ! -L $deployment_root/.env && -f $deployment_root/env/fleet.env && ! -L $deployment_root/env/fleet.env ]] || die 'canonical Compose environment input is unavailable'
}
deployment_root_identity() { stat -Lc '%d:%i' -- "$deployment_root"; }
canonical_compose_sha256() { sha256sum -- "$deployment_root/compose.yaml" | awk '{print $1}'; }
canonical_env_sha256() { sha256sum -- "$deployment_root/.env" "$deployment_root/env/fleet.env" | sha256sum | awk '{print $1}'; }
# Keep rendered config (which may contain secrets) inside the pipe. Do not add
# tee, command substitution of the raw render, or diagnostic output here.
compose=(docker compose --project-directory "$deployment_root" --env-file "$deployment_root/.env" -f "$deployment_root/compose.yaml")
staged_diff_sha256() { git -C "$repo" diff --cached --binary | sha256sum | awk '{print $1}'; }
rendered_compose_sha256() { (cd "$deployment_root" && "${compose[@]}" config 2>/dev/null | sha256sum | awk '{print $1}'); }
run_canonical_compose() { (cd "$deployment_root" && "${compose[@]}" "$@"); }
read_live_target() { docker inspect -f '{{.Id}}|{{.Image}}' "$container"; }
record_activation_preflight() {
  local staged_sha live root_id compose_input_sha env_sha compose_sha live_id live_image observed_candidate
  validate_canonical_deployment_root
  root_id=$(deployment_root_identity)
  compose_input_sha=$(canonical_compose_sha256)
  env_sha=$(canonical_env_sha256)
  staged_sha=$(staged_diff_sha256)
  live=$(read_live_target) || die 'canonical container target is missing'
  IFS='|' read -r live_id live_image <<<"$live"
  [[ $live_id =~ ^[[:alnum:]][[:alnum:]._-]*$ && $live_image =~ ^sha256:[[:xdigit:]]{64}$ ]] || die 'canonical container target is invalid'
  compose_sha=$(rendered_compose_sha256)
  [[ $root_id =~ ^[[:digit:]]+:[[:digit:]]+$ && $staged_sha =~ ^[[:xdigit:]]{64}$ && $compose_input_sha =~ ^[[:xdigit:]]{64}$ && $env_sha =~ ^[[:xdigit:]]{64}$ && $compose_sha =~ ^[[:xdigit:]]{64}$ ]] || die 'could not capture activation CAS evidence'
  printf '%s\n' "$head" >"$state/activation-head"
  printf '%s\n' "$staged_sha" >"$state/activation-staged-diff-sha256"
  printf '%s\n' "$container" >"$state/activation-container"
  printf '%s\n' "$live_id" >"$state/activation-container-id"
  printf '%s\n' "$live_image" >"$state/activation-live-image-id"
  printf '%s\n' "$root_id" >"$state/activation-deployment-root-id"
  printf '%s\n' "$compose_input_sha" >"$state/activation-compose-input-sha256"
  printf '%s\n' "$env_sha" >"$state/activation-env-sha256"
  printf '%s\n' "$compose_sha" >"$state/activation-compose-sha256"
  if observed_candidate=$(docker image inspect -f '{{.Id}}' "$candidate" 2>/dev/null); then
    [[ $observed_candidate =~ ^sha256:[[:xdigit:]]{64}$ ]] || die 'could not capture candidate image ID'
    printf '%s\n' "$observed_candidate" >"$state/activation-candidate-image-id"
  else
    rm -f "$state/activation-candidate-image-id"
  fi
}
verify_activation_cas() {
  local expected_head expected_staged expected_container expected_live_id expected_live_image expected_root_id expected_compose_input expected_env expected_compose expected_candidate live current_root_id current_compose_input current_env current_staged current_compose current_candidate
  for evidence in activation-head activation-staged-diff-sha256 activation-container activation-container-id activation-live-image-id activation-deployment-root-id activation-compose-input-sha256 activation-env-sha256 activation-compose-sha256 activation-candidate-image-id candidate-image-id; do
    [[ -s $state/$evidence ]] || die "missing activation CAS evidence: $evidence"
  done
  expected_head=$(<"$state/activation-head"); expected_staged=$(<"$state/activation-staged-diff-sha256"); expected_container=$(<"$state/activation-container"); expected_live_id=$(<"$state/activation-container-id"); expected_live_image=$(<"$state/activation-live-image-id"); expected_root_id=$(<"$state/activation-deployment-root-id"); expected_compose_input=$(<"$state/activation-compose-input-sha256"); expected_env=$(<"$state/activation-env-sha256"); expected_compose=$(<"$state/activation-compose-sha256"); expected_candidate=$(<"$state/activation-candidate-image-id")
  [[ $expected_container == "$canonical_container" && $container == "$expected_container" ]] || die 'canonical container target CAS mismatch'
  [[ $head == "$expected_head" ]] || die 'activation CAS mismatch: HEAD changed'
  validate_canonical_deployment_root
  current_root_id=$(deployment_root_identity); [[ $current_root_id == "$expected_root_id" ]] || die 'activation CAS mismatch: deployment root changed'
  current_compose_input=$(canonical_compose_sha256); [[ $current_compose_input == "$expected_compose_input" ]] || die 'activation CAS mismatch: Compose input changed'
  current_env=$(canonical_env_sha256); [[ $current_env == "$expected_env" ]] || die 'activation CAS mismatch: Compose environment changed'
  current_staged=$(staged_diff_sha256); [[ $current_staged == "$expected_staged" ]] || die 'activation CAS mismatch: staged diff changed'
  live=$(read_live_target) || die 'canonical container target is missing'
  [[ $live == "$expected_live_id|$expected_live_image" ]] || die 'activation CAS mismatch: live target changed'
  current_compose=$(rendered_compose_sha256); [[ $current_compose == "$expected_compose" ]] || die 'activation CAS mismatch: rendered Compose changed'
  current_candidate=$(docker image inspect -f '{{.Id}}' "$candidate") || die 'activation CAS mismatch: candidate missing'
  [[ $current_candidate == "$expected_candidate" && $current_candidate == $(<"$state/candidate-image-id") ]] || die 'activation CAS mismatch: candidate image changed'
}
# Reject unavailable canonical Compose inputs before creating candidate state.
validate_canonical_deployment_root
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
  run_canonical_compose up -d --no-deps --force-recreate "$compose_service" || rollback_rc=1
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
    # Lifecycle is owned by a detached guardian. The caller may disappear after this point without preventing the CAS-bound recovery path.
    guardian="$repo/ops/scripts/moss-promotion-guardian.sh"
    [[ -x $guardian ]] || die 'promotion guardian is unavailable'
    setsid "$guardian" --state "$state" --execute >"$state/guardian.log" 2>&1 < /dev/null &
    guardian_pid=$!
    printf '%s\n' "$guardian_pid" >"$state/guardian.pid"
    printf 'guardian_launched\npid=%s\n' "$guardian_pid" >"$state/status"
    ;;
esac
