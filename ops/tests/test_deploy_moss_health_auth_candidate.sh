#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT=${1:-ops/scripts/deploy-moss-health-auth-candidate.sh}
SCRIPT=$(realpath "$SCRIPT")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
root="$tmp/fixture-stack"
bin="$tmp/bin"
state="$tmp/state"
mkdir -p "$root" "$bin" "$state"
printf 'services:\n  moss:\n    image: fixture/moss:local\n' > "$root/compose.yaml"
git -C "$root" init -q
git -C "$root" config user.name test
git -C "$root" config user.email test@example.invalid
git -C "$root" add compose.yaml
git -C "$root" commit -qm fixture
stack_commit=$(git -C "$root" rev-parse HEAD)
rollback_id=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
candidate_id=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
image_ref=fixture/moss:local
container_name=moss-health-auth-rehearsal-test-moss-1
project=moss-health-auth-rehearsal-test
printf '%s\n' "$rollback_id" > "$state/tag-image"
printf '%s\n' "$rollback_id" > "$state/container-image"
printf '0\n' > "$state/health-inspects"

cat > "$bin/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
set -Eeuo pipefail
state=${FAKE_DOCKER_STATE:?}
if [[ "$1 $2" == "image inspect" ]]; then
  target=$3
  if [[ "$target" == sha256:* ]]; then printf '%s\n' "$target"; else cat "$state/tag-image"; fi
  exit 0
fi
if [[ "$1 $2" == "image tag" ]]; then
  printf '%s\n' "$3" > "$state/tag-image"
  exit 0
fi
if [[ "$1" == compose ]]; then
  shift
  while (($#)); do
    case "$1" in
      -p|-f) shift 2 ;;
      ps)
        printf 'fixture-cid\n'
        exit 0
        ;;
      up)
        cat "$state/tag-image" > "$state/container-image"
        exit 0
        ;;
      *) shift ;;
    esac
  done
fi
if [[ "$1" == inspect ]]; then
  format=$4
  case "$format" in
    *'.Name'*) printf '/%s\n' "$FAKE_CONTAINER_NAME" ;;
    *'.Image'*) cat "$state/container-image" ;;
    *'.State.Health'*)
      count=$(cat "$state/health-inspects")
      printf '%s\n' "$((count + 1))" > "$state/health-inspects"
      current=$(cat "$state/container-image")
      if [[ ${FAKE_FORCE_PROMOTION_FAILURE:-0} == 1 && "$current" == "$FAKE_CANDIDATE_ID" ]] || \
         [[ ${FAKE_FORCE_ROLLBACK_FAILURE:-0} == 1 && "$current" != "$FAKE_CANDIDATE_ID" ]]; then
        printf 'unhealthy\n'
      else
        printf 'healthy\n'
      fi
      ;;
    *) exit 2 ;;
  esac
  exit 0
fi
printf 'unexpected fake docker argv:' >&2
printf ' <%s>' "$@" >&2
printf '\n' >&2
exit 2
FAKE_DOCKER
chmod +x "$bin/docker" "$SCRIPT"

run_deploy() {
  local result=$1
  shift
  PATH="$bin:$PATH" \
  FAKE_DOCKER_STATE="$state" \
  FAKE_CONTAINER_NAME="$container_name" \
  FAKE_CANDIDATE_ID="$candidate_id" \
  MOSS_DEPLOY_COMPOSE_ROOT="$root" \
  MOSS_DEPLOY_PROJECT="$project" \
  MOSS_DEPLOY_CONTAINER_NAME="$container_name" \
  MOSS_DEPLOY_IMAGE_REF="$image_ref" \
  MOSS_DEPLOY_LOCK_FILE="$tmp/deploy.lock" \
  MOSS_DEPLOY_HEALTH_TIMEOUT_S=3 \
  "$SCRIPT" --rehearse \
    --expected-rollback-image-id "$rollback_id" \
    --candidate-image-id "$candidate_id" \
    --expected-stack-commit "$stack_commit" \
    --result "$result" "$@"
}

success_result="$tmp/success/result.json"
run_deploy "$success_result"
python3 - "$success_result" "$candidate_id" <<'PY'
import json, pathlib, sys
payload = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert payload["status"] == "promoted", payload
assert payload["active_image_id"] == sys.argv[2], payload
assert payload["active_container_id"] == "fixture-cid", payload
assert payload["healthy"] is True, payload
assert payload["operation"] == "promote", payload
assert payload["mode"] == "rehearsal", payload
PY
[[ $(cat "$state/container-image") == "$candidate_id" ]]
[[ $(stat -c '%a' "$success_result") == 600 ]]
! compgen -G "${success_result}.tmp.*" >/dev/null

rollback_only_result="$tmp/rollback-only/result.json"
health_inspects_before=$(cat "$state/health-inspects")
run_deploy "$rollback_only_result" --rollback-only
python3 - "$rollback_only_result" "$rollback_id" "$candidate_id" <<'PY'
import json, pathlib, sys
payload = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert payload["status"] == "rolled_back", payload
assert payload["reason"] == "post_promotion_validation_failed", payload
assert payload["active_image_id"] == sys.argv[2], payload
assert payload["active_container_id"] == "fixture-cid", payload
assert payload["healthy"] is True, payload
assert payload["operation"] == "rollback_only", payload
assert payload["candidate_image_id"] == sys.argv[3], payload
assert payload["rollback_image_id"] == sys.argv[2], payload
PY
[[ $(cat "$state/container-image") == "$rollback_id" ]]
[[ $(cat "$state/health-inspects") -gt $health_inspects_before ]]
[[ $(stat -c '%a' "$rollback_only_result") == 600 ]]
! compgen -G "${rollback_only_result}.tmp.*" >/dev/null

printf '%s\n' "$candidate_id" > "$state/tag-image"
printf '%s\n' "$candidate_id" > "$state/container-image"
rollback_failure_result="$tmp/rollback-only-failure/result.json"
set +e
rollback_failure_output=$(FAKE_FORCE_ROLLBACK_FAILURE=1 run_deploy "$rollback_failure_result" --rollback-only 2>&1)
rollback_failure_rc=$?
set -e
[[ $rollback_failure_rc -ne 0 ]]
[[ "$rollback_failure_output" != *"ROLLED_BACK"* ]]
python3 - "$rollback_failure_result" "$rollback_id" "$candidate_id" <<'PY'
import json, pathlib, sys
payload = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert payload["status"] == "rollback_failed", payload
assert payload["reason"] == "post_promotion_validation_failed", payload
assert payload["active_image_id"] == sys.argv[2], payload
assert payload["active_container_id"] == "fixture-cid", payload
assert payload["healthy"] is False, payload
assert payload["operation"] == "rollback_only", payload
assert payload["candidate_image_id"] == sys.argv[3], payload
assert payload["rollback_image_id"] == sys.argv[2], payload
PY
[[ $(cat "$state/container-image") == "$rollback_id" ]]
[[ $(stat -c '%a' "$rollback_failure_result") == 600 ]]
! compgen -G "${rollback_failure_result}.tmp.*" >/dev/null

printf '%s\n' "$rollback_id" > "$state/tag-image"
printf '%s\n' "$rollback_id" > "$state/container-image"
failure_result="$tmp/failure/result.json"
set +e
FAKE_FORCE_PROMOTION_FAILURE=1 run_deploy "$failure_result"
rc=$?
set -e
[[ $rc -ne 0 ]]
python3 - "$failure_result" "$rollback_id" <<'PY'
import json, pathlib, sys
payload = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert payload["status"] == "rolled_back", payload
assert payload["active_image_id"] == sys.argv[2], payload
assert payload["active_container_id"] == "fixture-cid", payload
assert payload["healthy"] is True, payload
assert payload["operation"] == "promote", payload
assert payload["reason"].startswith("promotion_failed_rc_"), payload
PY
[[ $(cat "$state/container-image") == "$rollback_id" ]]
[[ $(stat -c '%a' "$failure_result") == 600 ]]
! compgen -G "${failure_result}.tmp.*" >/dev/null

assert_rejected_image_id() {
  local which=$1 malformed=$2 result
  result="$tmp/rejected-$which-$(printf '%s' "$malformed" | tr -c '[:alnum:]' '_')/result.json"
  local rollback=$rollback_id candidate=$candidate_id
  if [[ "$which" == rollback ]]; then rollback=$malformed; else candidate=$malformed; fi
  set +e
  output=$(PATH="$bin:$PATH" \
    FAKE_DOCKER_STATE="$state" \
    FAKE_CONTAINER_NAME="$container_name" \
    FAKE_CANDIDATE_ID="$candidate_id" \
    MOSS_DEPLOY_COMPOSE_ROOT="$root" \
    MOSS_DEPLOY_PROJECT="$project" \
    MOSS_DEPLOY_CONTAINER_NAME="$container_name" \
    MOSS_DEPLOY_IMAGE_REF="$image_ref" \
    MOSS_DEPLOY_LOCK_FILE="$tmp/deploy.lock" \
    "$SCRIPT" --rehearse \
      --expected-rollback-image-id "$rollback" \
      --candidate-image-id "$candidate" \
      --expected-stack-commit "$stack_commit" \
      --result "$result" 2>&1)
  rc=$?
  set -e
  [[ $rc -eq 64 ]]
  [[ "$output" == *"canonical immutable sha256 IDs"* ]]
  [[ ! -e "$result" ]]
}

for malformed in \
  sha256: \
  sha256:abc \
  sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA \
  sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaG \
  sha257:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; do
  assert_rejected_image_id rollback "$malformed"
  assert_rejected_image_id candidate "$malformed"
done

printf 'deploy-script-tests: PASS (promotion, rollback-only, failed rollback-only, forced-failure rollback, malformed-ID rejection)\n'
