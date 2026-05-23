#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import json
from pathlib import Path

lock_path = Path('ops/manifests/base-images.lock.json')
if not lock_path.is_file():
    raise SystemExit('image_pin_failed: missing ops/manifests/base-images.lock.json')
lock = json.loads(lock_path.read_text())
images = lock.get('images', [])
if len(images) != 1:
    raise SystemExit('image_pin_failed: expected exactly one base image record')
image = images[0].get('image', '')
if not image.startswith('nousresearch/hermes-agent@sha256:') or len(image.rsplit(':', 1)[-1]) != 64:
    raise SystemExit('image_pin_failed: hermes-agent image must be digest-pinned')
if lock.get('status') != 'pinned-for-public-scaffold':
    raise SystemExit('image_pin_failed: lock status must be pinned-for-public-scaffold')
for dockerfile_name in images[0].get('used_by', []):
    dockerfile = Path(dockerfile_name)
    if not dockerfile.is_file():
        raise SystemExit(f'image_pin_failed: missing {dockerfile}')
    content = dockerfile.read_text()
    if 'nousresearch/hermes-agent:latest' in content:
        raise SystemExit(f'image_pin_failed: {dockerfile} still references :latest')
    expected_arg = f'ARG HERMES_AGENT_IMAGE={image}'
    if expected_arg not in content:
        raise SystemExit(f'image_pin_failed: {dockerfile} missing pinned ARG default')
    if 'FROM ${HERMES_AGENT_IMAGE}' not in content:
        raise SystemExit(f'image_pin_failed: {dockerfile} must use FROM ${{HERMES_AGENT_IMAGE}}')
print('image_pin_ok')
PY
