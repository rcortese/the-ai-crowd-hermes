#!/usr/bin/env bash
set -euo pipefail
base=the-ai-crowd/moss-all-in-one:rollback-before-webui-api-intermediate-prod-20260701T044611Z
expected_base=sha256:31a88b842a2356f70538c4e441e38e235333e6274fd031ce78cad469ce4ed861
tag=${1:-the-ai-crowd/moss-all-in-one:preapi-context-repro}
dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
actual=$(docker image inspect -f '{{.Id}}' "$base")
[ "$actual" = "$expected_base" ] || {
  printf 'base image mismatch: %s != %s\n' "$actual" "$expected_base" >&2
  exit 2
}
docker build -t "$tag" "$dir"
id=$(docker create "$tag")
trap 'docker rm -f "$id" >/dev/null 2>&1 || true' EXIT
docker cp "$id:/opt/hermes-webui/static/ui.js" "$dir/.ui.verify"
docker cp "$id:/opt/hermes-webui/api/background_process.py" "$dir/.background-process.verify"
got=$(sha256sum "$dir/.ui.verify" | cut -d' ' -f1)
background_got=$(sha256sum "$dir/.background-process.verify" | cut -d' ' -f1)
rm -f "$dir/.ui.verify" "$dir/.background-process.verify"
[ "$got" = 103a13a48e1729e09678a2d4c96f0282e1cfebe8b8cfd11f1b0d95705738328f ] || {
  printf 'ui checksum mismatch: %s\n' "$got" >&2
  exit 3
}
[ "$background_got" = 208233b5916c6a8eed64922d59211e98c20614006f421ea2d19d84ed5eee4289 ] || {
  printf 'background_process checksum mismatch: %s\n' "$background_got" >&2
  exit 4
}
docker image inspect -f '{{.Id}}' "$tag"
