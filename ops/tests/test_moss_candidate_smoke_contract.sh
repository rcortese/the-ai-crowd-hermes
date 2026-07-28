#!/usr/bin/env bash
set -Eeuo pipefail
root=${1:?source root required}
smoke=${MOSS_SMOKE_SCRIPT:-$root/tests/smoke-deploy.sh}
[[ -x $smoke ]] || { printf '%s\n' 'SMOKE CONTRACT ASSERT: smoke helper missing' >&2; exit 1; }
fail(){ printf 'SMOKE CONTRACT ASSERT: %s\n' "$*" >&2; exit 1; }
fx=$(mktemp -d /tmp/moss-smoke-contract.XXXXXX)
trap 'rm -rf -- "$fx"' EXIT
bin=$fx/bin; log=$fx/docker.log; capture=$fx/override.yaml
mkdir -p "$bin"
candidate=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
production='prod-container-id|sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|2026-07-23T00:00:00Z|0|true|running|healthy'
production_changed='prod-container-id|sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|2026-07-23T00:00:00Z|0|true|running|unhealthy'
cat >"$bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '<%s>' "$@" >>"${DOCKER_LOG:?}"
printf '\n' >>"$DOCKER_LOG"
case ${1:-} in
  info) exit 0 ;;
  image)
    [[ ${2:-} == inspect && ${4:-} == --format && ${5:-} == '{{.Id}}' ]] || exit 91
    printf '%s\n' "${FIXTURE_IMAGE_ID:?}"
    ;;
  inspect)
    if [[ ${2:-} == the-ai-crowd-moss-1 ]]; then
      count=$(<"${INSPECT_COUNTER:?}")
      count=$((count + 1))
      printf '%s\n' "$count" >"$INSPECT_COUNTER"
      if ((count >= 2)) && [[ -n ${FAKE_PRODUCTION_AFTER:-} ]]; then
        printf '%s\n' "$FAKE_PRODUCTION_AFTER"
      else
        printf '%s\n' "${FIXTURE_PRODUCTION:?}"
      fi
    elif [[ ${4:-} == '{{.Image}}' ]]; then
      printf '%s\n' "${FIXTURE_IMAGE_ID:?}"
    else
      exit 91
    fi
    ;;
  compose)
    args=("$@")
    sub=
    for arg in "$@"; do
      case $arg in config|up|down|ps|exec|logs) sub=$arg; break;; esac
    done
    case $sub in
      config)
        last_f=
        for ((i=0;i<${#args[@]};i++)); do
          [[ ${args[$i]} == -f ]] && last_f=${args[$((i+1))]}
        done
        cp -- "$last_f" "${CAPTURE_OVERRIDE:?}"
        printf '%s\n' 'services: {moss: {image: fixture}}'
        ;;
      up|exec|logs) exit 0 ;;
      down) [[ ${FAKE_DOWN_FAIL:-0} == 1 ]] && exit 97 || exit 0 ;;
      ps)
        [[ $* == *' -q moss'* ]] && printf '%s\n' fixture-smoke-container || true
        ;;
      *) exit 91 ;;
    esac
    ;;
  *) exit 91 ;;
esac
DOCKER
chmod 700 "$bin/docker"
: >"$log"
counter=$fx/inspect.counter
printf '0\n' >"$counter"
PATH="$bin:$PATH" DOCKER_LOG="$log" INSPECT_COUNTER="$counter" CAPTURE_OVERRIDE="$capture" FIXTURE_IMAGE_ID="$candidate" FIXTURE_PRODUCTION="$production" MOSS_SMOKE_IMAGE=fixture/moss:candidate "$smoke" >"$fx/run.out" 2>&1 || { cat "$fx/run.out" >&2; fail 'smoke harness failed under fake daemon'; }

grep -Fq "<image><inspect><fixture/moss:candidate><--format><{{.Id}}>" "$log" || fail 'candidate tag was not resolved to image ID'
grep -Eq '<compose><--project-name><moss-accept-[^>]+>' "$log" || fail 'project identity is not unique candidate namespace'
! grep -Fq '<compose><--project-name><the-ai-crowd>' "$log" || fail 'production project namespace used'
grep -Fq '<up><-d><--no-build><--no-deps><moss>' "$log" || fail 'up command lacks no-build/no-deps'
! grep -Eq '<up>[^\n]*<--build>' "$log" || fail 'implicit build present'
grep -Fq '<down><--remove-orphans><--volumes>' "$log" || fail 'bounded project cleanup missing'
[[ $(grep -Fc '<inspect><the-ai-crowd-moss-1>' "$log") == 2 ]] || fail 'production identity was not checked before and after'
grep -Fq 'image: ${MOSS_SMOKE_IMAGE_ID}' "$capture" || fail 'override does not bind resolved image ID'
! grep -Eq '(\./agents|\./state|THE_AI_CROWD_BACKUP_ROOT|external:)' "$capture" || fail 'override references production mounts or network'
[[ $(grep -Fc '${MOSS_SMOKE_ROOT}/' "$capture") == 6 ]] || fail 'all six smoke mounts are not rooted in one temporary directory'

echo 'moss-candidate-smoke-contract: PASS image-id=true unique-project=true no-build=true temporary-mounts=6 production-invariant=true'

run_negative(){
  local label=$1 expected=$2
  shift 2
  local rc=0 out="$fx/$label.out"
  printf '0\n' >"$counter"
  set +e
  env PATH="$bin:$PATH" DOCKER_LOG="$log" INSPECT_COUNTER="$counter" CAPTURE_OVERRIDE="$capture" FIXTURE_IMAGE_ID="$candidate" FIXTURE_PRODUCTION="$production" MOSS_SMOKE_IMAGE=fixture/moss:candidate "$@" "$smoke" >"$out" 2>&1
  rc=$?
  set -e
  [[ $rc == "$expected" ]] || { cat "$out" >&2; fail "$label expected rc=$expected got rc=$rc"; }
}
run_negative production-drift 83 FAKE_PRODUCTION_AFTER="$production_changed"
grep -Fq 'smoke_deploy_failed: production identity changed' "$fx/production-drift.out" || fail 'production drift oracle absent'
run_negative cleanup-failure 81 FAKE_DOWN_FAIL=1
cleanup_root=$(sed -n 's/.* root=\([^ ]*\) retained=true.*/\1/p' "$fx/cleanup-failure.out")
[[ -n $cleanup_root && -d $cleanup_root && -f $cleanup_root/compose.yaml ]] || fail 'cleanup failure did not retain diagnostic root'
rm -rf -- "$cleanup_root"
echo 'moss-candidate-smoke-negatives: PASS production-drift=83 cleanup-failure=81 retained=true'

if [[ ${MOSS_SMOKE_CONTRACT_CHILD:-0} != 1 ]]; then
  mutate_and_expect_red(){
    local label=$1 old=$2 new=$3
    local mutant="$fx/$label.sh" body rc=0
    body=$(<"$smoke")
    [[ $body == *"$old"* ]] || fail "$label mutant anchor missing"
    printf '%s' "${body/"$old"/"$new"}" >"$mutant"
    chmod 755 "$mutant"
    set +e
    MOSS_SMOKE_CONTRACT_CHILD=1 MOSS_SMOKE_SCRIPT="$mutant" bash "$0" "$root" >"$fx/$label.out" 2>&1
    rc=$?
    set -e
    [[ $rc != 0 ]] || fail "$label mutant survived"
  }
  mutate_and_expect_red implicit-build 'up -d --no-build --no-deps moss' 'up -d --build --no-deps moss'
  mutate_and_expect_red production-project 'project="moss-accept-$(date -u +%s)-$$"' 'project="the-ai-crowd"'
  mutate_and_expect_red production-volume '${MOSS_SMOKE_ROOT}/private:/agents/moss/private:rw' './agents/private/moss:/agents/moss/private:rw'
  mutate_and_expect_red mutable-image '    image: ${MOSS_SMOKE_IMAGE_ID}' '    image: ${MOSS_SMOKE_IMAGE}'
  echo 'moss-candidate-smoke-mutations: PASS total=4 causal-red=true'
fi
