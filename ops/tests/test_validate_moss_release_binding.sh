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
cat > "$tmp/release.env" <<EOF
MOSS_BASE_IMAGE=fixture/base:immutable
EOF
cat > "$bin/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "$1 $2" == 'image inspect' ]]; then printf '%s\n' "$3"; exit 0; fi
if [[ "$*" == *'config --format json'* ]]; then printf '{"services":{"moss":{"image":"%s"}}}\n' "${MOSS_IMAGE_REF:?}"; exit 0; fi
exit 2
EOF
chmod +x "$bin/docker"
PATH="$bin:$PATH" MOSS_IMAGE_REF="$candidate" MOSS_BASE_IMAGE=fixture/base:immutable bash "$script" --compose-root "$root" --env-file "$tmp/release.env" --expected-image-ref "$candidate" --expected-rollback-image-ref "$rollback" --moss-base-image fixture/base:immutable
PATH="$bin:$PATH" MOSS_IMAGE_REF=fixture/moss:hostile-tag MOSS_BASE_IMAGE=hostile/base:tag bash "$script" --compose-root "$root" --env-file "$tmp/release.env" --expected-image-ref "$candidate" --expected-rollback-image-ref "$rollback" --moss-base-image fixture/base:immutable
printf '%s\n' 'release-binding-tests: PASS'
