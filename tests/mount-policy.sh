#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
repo_root="$(pwd -P)"

render_and_scan() {
  local label="$1"
  shift
  local rendered
  rendered="$($@)"
  REPO_ROOT="$repo_root" RENDERED_COMPOSE="$rendered" python3 - "$label" <<'PY'
import os
import re
import sys
from pathlib import Path

label = sys.argv[1]
text = os.environ['RENDERED_COMPOSE']
repo_root = Path(os.environ['REPO_ROOT']).resolve()

for pattern, message in [
    (r'/var/run/docker\.sock', 'Docker socket must not be mounted by default'),
    (r'(?<![A-Za-z0-9_.-])(?:10\.|172\.(?:1[6-9]|2[0-9]|3[0-1])\.|192\.168\.)\d{1,3}\.\d{1,3}\b', 'private IPv4 in rendered Compose'),
    (r'(?<![A-Za-z0-9_.-])[A-Za-z0-9-]+\.lan\b', 'LAN hostname in rendered Compose'),
    (r'\.ssh(?:/|$)', 'SSH material path in rendered Compose'),
    (r'\bid_(?:rsa|ed25519)\b', 'SSH key name in rendered Compose'),
    (r'\bauth\.json\b', 'auth state in rendered Compose'),
    (r'\.anthropic_oauth\.json\b', 'OAuth state in rendered Compose'),
    (r'config\.yaml\s*:', 'private config bind in rendered Compose'),
]:
    if re.search(pattern, text):
        raise SystemExit(f'{label}: {message}')

allowed_targets = {
    '/opt/data',
    '/mnt/hermes-shared',
    '/workspace/the-ai-crowd',
    '/workspace/richmond',
    '/workspace/projects/example-project',
}
source = None
for line in text.splitlines():
    stripped = line.strip()
    if stripped.startswith('source:'):
        source = stripped.split(':', 1)[1].strip().strip('"\'')
    elif stripped.startswith('target:') and source is not None:
        target = stripped.split(':', 1)[1].strip().strip('"\'')
        if source in {'/', '/home'}:
            raise SystemExit(f'{label}: broad host bind source {source!r}')
        if target not in allowed_targets:
            raise SystemExit(f'{label}: unexpected bind target {target!r} from source {source!r}')
        if source.startswith('/PUBLIC_PLACEHOLDER/'):
            source = None
            continue
        try:
            resolved_source = Path(source).resolve()
        except OSError:
            raise SystemExit(f'{label}: cannot resolve bind source {source!r}')
        if not (resolved_source == repo_root or repo_root in resolved_source.parents):
            raise SystemExit(f'{label}: bind source is outside repository for target {target!r}')
        source = None

for pattern in [
    r'(?m)^\s*-\s*/\s*:',
    r'(?m)^\s*-\s*/home\s*:',
    r'(?m)^\s*source:\s*/\s*$\n\s*target:',
    r'(?m)^\s*source:\s*/home\s*$\n\s*target:',
]:
    if re.search(pattern, text):
        raise SystemExit(f'{label}: broad host mount matched {pattern}')

for required in ['HERMES_UID: "1000"', 'HERMES_GID: "1000"']:
    if required not in text:
        raise SystemExit(f'{label}: services must default {required} for entrypoint UID/GID remap')
if 'HOME: /opt/data' not in text:
    raise SystemExit(f'{label}: HOME must point at /opt/data for non-root runtime state')

if label == 'project_example':
    project_block = re.search(r'target:\s*/workspace/projects/example-project(?:.|\n){0,300}', text)
    if not project_block or 'read_only: true' not in project_block.group(0):
        raise SystemExit('project_example: example project mount must remain read_only: true')

print(f'{label}_mount_policy_ok')
PY
}

compose_cmd=(docker compose)
if ! docker compose version >/dev/null 2>&1; then
  if command -v docker-compose >/dev/null 2>&1; then
    compose_cmd=(docker-compose)
  else
    echo 'mount_policy_blocked: docker compose is unavailable' >&2
    exit 2
  fi
fi

render_and_scan base "${compose_cmd[@]}" -f compose.yaml config
HERMES_EXAMPLE_PROJECTS_ROOT=/PUBLIC_PLACEHOLDER/projects \
  render_and_scan project_example "${compose_cmd[@]}" -f compose.yaml -f compose.project-mount.example.yaml config
