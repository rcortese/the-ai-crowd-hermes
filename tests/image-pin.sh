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
record = images[0]
image = record.get('image', '')
source_rev = record.get('source_rev', '')
if lock.get('status') != 'pinned-fork-source':
    raise SystemExit('image_pin_failed: lock status must be pinned-fork-source')
if not image.startswith('the-ai-crowd/hermes-agent:release-v2026.7.1-fork-'):
    raise SystemExit('image_pin_failed: hermes-agent image must be the local fork release tag')
if len(source_rev) != 40 or not all(c in '0123456789abcdef' for c in source_rev.lower()):
    raise SystemExit('image_pin_failed: source_rev must be a full git SHA')
if not image.endswith(source_rev[:12]):
    raise SystemExit('image_pin_failed: image tag suffix must match source_rev[:12]')
if record.get('patch_commits') != 5:
    raise SystemExit('image_pin_failed: patch_commits must be 5 for current fork patch stack')
if record.get('source_repo') != 'https://github.com/rcortese/hermes-agent':
    raise SystemExit('image_pin_failed: source_repo must be the The AI Crowd fork')
if record.get('release_base') != 'v2026.7.1':
    raise SystemExit('image_pin_failed: release_base mismatch')
for dockerfile_name in record.get('used_by', []):
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
