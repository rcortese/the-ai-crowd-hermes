#!/usr/bin/env bash
set -Eeuo pipefail

script=$(realpath "${1:-ops/scripts/validate-moss-release-binding.sh}")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
root="$tmp/stack"
bin="$tmp/bin"
mkdir -p "$root" "$bin"

candidate=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
rollback=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
cat > "$root/compose.yaml" <<'YAML'
services:
  moss:
    image: ${MOSS_IMAGE_REF:-fixture/moss:${THE_AI_CROWD_IMAGE_TAG:-local}}
YAML
cat > "$tmp/release.env" <<EOF
THE_AI_CROWD_IMAGE_TAG=local
MOSS_IMAGE_REF=$candidate
MOSS_ROLLBACK_IMAGE_REF=$rollback
EOF
cat > "$bin/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "$1 $2" == 'image inspect' ]]; then
  target=$3
  [[ "${FAKE_MISSING_IMAGE:-}" != "$target" ]] || exit 1
  printf '%s\n' "$target"
  exit 0
fi
if [[ "$*" == *"config --format json"* ]]; then
  image=$(grep '^MOSS_IMAGE_REF=' "${FAKE_ENV_FILE:?}" | cut -d= -f2-)
  printf '{"services":{"moss":{"image":"%s"}}}\n' "$image"
  exit 0
fi
exit 2
EOF
chmod +x "$bin/docker"

PATH="$bin:$PATH" FAKE_ENV_FILE="$tmp/release.env" bash "$script" \
  --compose-root "$root" --env-file "$tmp/release.env" \
  --expected-image-ref "$candidate" --expected-rollback-image-ref "$rollback"

printf 'MOSS_IMAGE_REF=fixture/moss:local\nMOSS_ROLLBACK_IMAGE_REF=%s\n' "$rollback" > "$tmp/wrong.env"
set +e
output=$(PATH="$bin:$PATH" FAKE_ENV_FILE="$tmp/wrong.env" bash "$script" \
  --compose-root "$root" --env-file "$tmp/wrong.env" \
  --expected-image-ref "$candidate" --expected-rollback-image-ref "$rollback" 2>&1)
rc=$?
set -e
[[ $rc -eq 65 && "$output" == *'does not bind the expected candidate'* ]]

set +e
output=$(PATH="$bin:$PATH" FAKE_ENV_FILE="$tmp/release.env" FAKE_MISSING_IMAGE="$rollback" bash "$script" \
  --compose-root "$root" --env-file "$tmp/release.env" \
  --expected-image-ref "$candidate" --expected-rollback-image-ref "$rollback" 2>&1)
rc=$?
set -e
[[ $rc -eq 66 && "$output" == *"required local image is unavailable: $rollback"* ]]

printf 'release-binding-tests: PASS (immutable resolution, mutable-tag rejection, missing-image rejection)\n'
