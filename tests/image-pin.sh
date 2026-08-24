#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
python3 - <<'PY'
import json
from pathlib import Path

root = Path('.')
lock = json.loads((root / 'ops/manifests/protected-hermes-a2a-base.lock.json').read_text())
if lock.get('schema') != 'the-ai-crowd-hermes.protected-a2a-base-lock.v2':
    raise SystemExit('image_pin_failed: unexpected protected-base lock schema')
record = lock.get('protected_base') or {}
image = record.get('image', '')
image_id = record.get('image_id', '')
revision = record.get('source_revision', '')
if not image.startswith('the-ai-crowd/hermes-base:g1-74'):
    raise SystemExit('image_pin_failed: approved protected Hermes 74 base tag required')
if not image_id.startswith('sha256:') or len(image_id.split(':', 1)[-1]) != 64:
    raise SystemExit('image_pin_failed: immutable Docker image ID required')
if len(revision) != 40:
    raise SystemExit('image_pin_failed: exact Hermes source revision required')
if lock.get('status') != 'approved-protected-base-consumption':
    raise SystemExit('image_pin_failed: approved protected-base consumption required')
personas = ['moss', 'jen', 'denholm', 'richmond', 'roy', 'the-elders']
if lock.get('persona_consumers') != personas:
    raise SystemExit('image_pin_failed: every Stack persona must consume the protected base')
for persona in personas:
    dockerfile_name = f'ops/images/Dockerfile.{persona}'
    lines = (root / dockerfile_name).read_text().splitlines()
    if lines[:2] != ['ARG HERMES_AGENT_IMAGE', 'FROM ${HERMES_AGENT_IMAGE}']:
        raise SystemExit(f'image_pin_failed: {dockerfile_name} must require an explicit build argument')
helper = (root / 'ops/scripts/build-persona-base-candidate.sh').read_text()
if 'base-images.lock.json' in helper:
    raise SystemExit('image_pin_failed: persona builder must not consume legacy base-images lock')
for required in ('docker image inspect "$BASE_TAG"', '[[ "$ACTUAL_ID" == "$EXPECTED_ID" ]]', '--build-arg "HERMES_AGENT_IMAGE=$BASE_TAG"', 'the-ai-crowd.hermes-base-id=$EXPECTED_ID', 'the-ai-crowd.hermes-base-source-revision=$BASE_SOURCE_REVISION'):
    if required not in helper:
        raise SystemExit(f'image_pin_failed: builder missing gate: {required}')
print('image_pin_ok')
PY
