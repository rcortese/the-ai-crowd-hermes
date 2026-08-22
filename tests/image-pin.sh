#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import json
from pathlib import Path
root = Path('.')
lock = json.loads((root / 'ops/manifests/base-images.lock.json').read_text())
if lock.get('schema') != 'the-ai-crowd-hermes.base-images-lock.v1':
    raise SystemExit('image_pin_failed: unexpected lock schema')
images = lock.get('images') or []
if len(images) != 1:
    raise SystemExit('image_pin_failed: expected exactly one base image record')
record = images[0]
image = record.get('image', '')
image_id = record.get('image_id', '')
revision = record.get('source_revision', '')
if not image.startswith('the-ai-crowd/hermes-agent:a2a-'):
    raise SystemExit('image_pin_failed: controlled local base tag required')
if not image_id.startswith('sha256:') or len(image_id.split(':', 1)[-1]) != 64:
    raise SystemExit('image_pin_failed: immutable Docker image ID required')
if len(revision) != 40:
    raise SystemExit('image_pin_failed: exact Hermes source revision required')
if lock.get('status') != 'pinned-for-public-scaffold':
    raise SystemExit('image_pin_failed: lock status must be pinned-for-public-scaffold')
for dockerfile_name in record.get('used_by', []):
    lines = (root / dockerfile_name).read_text().splitlines()
    if lines[:2] != ['ARG HERMES_AGENT_IMAGE', 'FROM ${HERMES_AGENT_IMAGE}']:
        raise SystemExit(f'image_pin_failed: {dockerfile_name} must require an explicit build argument')
rebind = json.loads((root / 'ops/manifests/fleet-hermes-918b-rebind.lock.json').read_text())
if rebind.get('schema') != 'the-ai-crowd.fleet-hermes-918b-rebind-lock.v1' or rebind.get('status') != 'source-only-quarantined':
    raise SystemExit('image_pin_failed: rebind lock schema/status mismatch')
if rebind.get('base', {}).get('tag') != 'the-ai-crowd/hermes-base:918b36785653' or rebind.get('base', {}).get('local_image_id') is not None:
    raise SystemExit('image_pin_failed: rebind lock must pin tag with an unbound local ID slot')
if rebind.get('base', {}).get('source', {}).get('commit') != '918b36785653ec291806558e30b302b8cad10777':
    raise SystemExit('image_pin_failed: rebind source commit mismatch')
validator = (root / 'ops/release/fleet_hermes_918b_rebind.py').read_text()
if '--require-local-image-id' not in validator:
    raise SystemExit('image_pin_failed: rebind validator lacks local-ID fail-close')
helper = (root / 'ops/scripts/build-persona-base-candidate.sh').read_text()
for required in ('docker image inspect "$BASE_TAG"', '[[ "$ACTUAL_ID" == "$EXPECTED_ID" ]]', '--build-arg "HERMES_AGENT_IMAGE=$BASE_TAG"', 'HERMES_BASE_REBIND_LOCK', 'the-ai-crowd.hermes-base-tag=$BASE_TAG'):
    if required not in helper:
        raise SystemExit(f'image_pin_failed: builder missing gate: {required}')
print('image_pin_ok')
PY
