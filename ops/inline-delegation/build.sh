#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
base='sha256:05838ef5c373b913f4a0652ca76f4f0ca827c6a18754b2616a39a6d02a9df005'
tag='moss-terminal-aggregate:release-959381e4d17344398665f44b8e6407d7'
candidate='local/moss-inline-delegation:prepared-v1'
[[ "$(docker image inspect "$tag" --format '{{.Id}}')" == "$base" ]] || { printf 'base image drift\n' >&2; exit 1; }
[[ "$(docker inspect the-ai-crowd-moss-1 --format '{{.Image}}')" == "$base" ]] || { printf 'running image drift\n' >&2; exit 1; }
docker build --pull=false -t "$candidate" -f Dockerfile .
[[ "$(docker image inspect "$tag" --format '{{.Id}}')" == "$base" ]] || { printf 'base moved during build\n' >&2; exit 1; }
id="$(docker image inspect "$candidate" --format '{{.Id}}')"
[[ "$id" != "$base" ]] || { printf 'candidate equals base\n' >&2; exit 1; }
docker run --rm --network none --entrypoint /bin/sh "$id" -c '
  set -eu
  printf "%s  %s\n" \
    af84277268986a36db192e70c716645ec2c4a1e28f32f000657ecf4055c4ba84 /opt/hermes/gateway/platforms/api_server_openai_routes.py \
    1b406016503f4cded06e081c154379d5af0903fb699a0d2ad20096b54f5ac1a8 /opt/hermes/gateway/platforms/api_server_runs.py \
    73094c5a27be52718d966aa0aa62e34d81d55f716853718ea66b3eb35ddfccc3 /opt/hermes-webui/api/gateway_chat.py | sha256sum -c -
  /opt/hermes/.venv/bin/python3 -c "import gateway.platforms.api_server_openai_routes, gateway.platforms.api_server_runs; import sys; sys.path.insert(0, \"/opt/hermes-webui\"); import api.gateway_chat; print(\"imports_ok\")"
'
printf 'CANDIDATE_IMAGE_ID=%s\n' "$id"
