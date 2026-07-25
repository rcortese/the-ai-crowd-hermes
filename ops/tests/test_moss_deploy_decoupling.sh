#!/usr/bin/env bash
# Source-only contract: Moss deploy rendering is independent from candidate build inputs.
set -Eeuo pipefail
source_root=${1:?root required}
compose_source="$source_root/compose.yaml"
builder="$source_root/ops/scripts/build-moss-all-in-one-candidate.sh"
smoke="$source_root/tests/smoke-deploy.sh"
[[ -f $compose_source && -x $builder && -x $smoke ]] || { printf '%s\n' 'deploy-decoupling: source inputs missing' >&2; exit 66; }

fail(){ printf 'DEPLOY DECOUPLING ASSERT: %s\n' "$*" >&2; exit 1; }
fx=$(mktemp -d /tmp/moss-deploy-decoupling.XXXXXX)
trap 'rm -rf -- "$fx"' EXIT
stack="$fx/stack"
mkdir -p "$stack/env" "$fx/bin"
cp -- "$compose_source" "$stack/compose.yaml"
: >"$stack/.env"
: >"$stack/env/fleet.env"
: >"$stack/env/moss-webui.env"
: >"$stack/env/roy.env"

candidate=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
builder_base=$(git -C "$source_root" rev-parse HEAD^)
render_contract(){
  local compose_file=$1 out=$2
  shift 2
  # Compose may normalize an unused build section out of rendered JSON when an
  # explicit image is present, so reject source coupling before rendering.
  if awk '
    $0 == "  moss:" { in_moss=1; next }
    in_moss && /^  [[:alnum:]_-]+:$/ { exit }
    in_moss && $0 == "    build:" { found=1 }
    END { exit(found ? 0 : 1) }
  ' "$compose_file"; then
    return 42
  fi
  env -i HOME=/root PATH="$PATH" THE_AI_CROWD_IMAGE_TAG=scaffold MOSS_IMAGE_REF="$candidate" "$@" \
    docker compose --project-directory "$stack" --env-file "$stack/.env" -f "$compose_file" config --format json >"$out"
  jq -e --arg image "$candidate" \
    '.services.moss.image==$image and (.services.moss|has("build")|not)' "$out" >/dev/null
  ! grep -Eq 'MOSS_BASE_IMAGE|CLASH_ROYALE_BUILD_INPUT_DIR' "$out" || fail 'render leaked build-only inputs'
}

# Deploy rendering succeeds with both build-only variables absent and selects the candidate.
render_contract "$stack/compose.yaml" "$fx/render.json"

# The builder fails closed before Docker when the required immutable base is absent.
cat >"$fx/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
printf '%s\n' invoked >>"${DOCKER_LOG:?}"
exit 99
DOCKER
chmod 700 "$fx/bin/docker"
: >"$fx/docker.log"
rc=0
env -i HOME=/root PATH="$fx/bin:$PATH" DOCKER_LOG="$fx/docker.log" HDDT_SOURCE_BASE_REVISION="$builder_base" bash "$builder" fixture/moss:test >"$fx/missing-base.out" 2>&1 || rc=$?
(( rc != 0 )) || fail 'builder accepted missing base image'
grep -Fq 'MOSS_BASE_IMAGE must be an immutable local sha256 image ID' "$fx/missing-base.out" || fail 'missing base image oracle absent'
[[ ! -s $fx/docker.log ]] || fail 'builder invoked Docker without base image'

# Smoke deploy requires the selector and can never request an implicit build.
grep -Fq 'IMAGE_REF="${MOSS_SMOKE_IMAGE:-${MOSS_IMAGE_REF:-}}"' "$smoke" || fail 'smoke does not require explicit candidate selector'
grep -Fq '"${compose[@]}" up -d --no-build --no-deps moss' "$smoke" || fail 'smoke does not use up --no-build --no-deps moss'
! grep -Fq -- '--build' "$smoke" || fail 'smoke still contains --build'

# Causal mutant: restoring Moss build/coupling must fail the rendered no-build
# contract regardless of whether Compose interpolates unused build arguments.
awk '
  { print }
  $0 == "  moss:" {
    print "    build:"
    print "      context: ."
    print "      dockerfile: ops/images/Dockerfile.moss-all-in-one"
    print "      args:"
    print "        MOSS_BASE_IMAGE: ${MOSS_BASE_IMAGE:?build input required}"

  }
' "$stack/compose.yaml" >"$fx/mutant.yaml"
rc=0
render_contract "$fx/mutant.yaml" "$fx/mutant-unset.json" >"$fx/mutant-unset.out" 2>&1 || rc=$?
(( rc != 0 )) || fail 'no-build contract accepted build-coupled mutant without inputs'
rc=0
render_contract "$fx/mutant.yaml" "$fx/mutant-supplied.json" MOSS_BASE_IMAGE=fixture/base:immutable >"$fx/mutant-supplied.out" 2>&1 || rc=$?
(( rc != 0 )) || fail 'no-build contract accepted build-coupled mutant with inputs'

printf '%s\n' 'moss-deploy-decoupling: PASS render-no-build-inputs=true selector=true builder-fail-closed=true smoke-no-build=true mutant=RED'
