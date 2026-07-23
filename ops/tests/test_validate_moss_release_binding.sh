#!/usr/bin/env bash
set -Eeuo pipefail
script=$(realpath "${1:-ops/scripts/validate-moss-release-binding.sh}")
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
root="$tmp/stack"; bin="$tmp/bin"; mkdir -p "$root" "$bin"
candidate=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
rollback=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
cat > "$root/compose.yaml" <<'YAML'
services:
  moss:
    image: ${MOSS_IMAGE_REF:-fixture/moss:${THE_AI_CROWD_IMAGE_TAG:-local}}
YAML
: > "$tmp/release.env"
cat > "$bin/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "$1 $2" == 'image inspect' ]]; then printf '%s\n' "$3"; exit 0; fi
if [[ "$*" == *'config --format json'* ]]; then [[ -z ${HDDT_BINDING_HOSTILE:-} && -z ${MOSS_BASE_IMAGE+x} && -z ${CLASH_ROYALE_BUILD_INPUT_DIR+x} ]] || exit 23; printf '{"services":{"moss":{"image":"%s"}}}\n' "${MOSS_IMAGE_REF:?}"; exit 0; fi
exit 2
EOF
chmod +x "$bin/docker"
HDDT_BINDING_HOSTILE=ambient PATH="$bin:$PATH" MOSS_IMAGE_REF="$candidate" MOSS_BASE_IMAGE=hostile/base:tag CLASH_ROYALE_BUILD_INPUT_DIR=/hostile bash "$script" --compose-root "$root" --env-file "$tmp/release.env" --expected-image-ref "$candidate" --expected-rollback-image-ref "$rollback"
HDDT_BINDING_HOSTILE=ambient PATH="$bin:$PATH" MOSS_IMAGE_REF=fixture/moss:hostile-tag MOSS_BASE_IMAGE=hostile/base:tag CLASH_ROYALE_BUILD_INPUT_DIR=/hostile bash "$script" --compose-root "$root" --env-file "$tmp/release.env" --expected-image-ref "$candidate" --expected-rollback-image-ref "$rollback"
printf '%s\n' 'release-binding-tests: PASS'
