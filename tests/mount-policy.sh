#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Static source policy, not a Docker/Compose render or live mount verification.
export PYTHONDONTWRITEBYTECODE=1
python3 -m unittest discover -s tests -p 'test_public_scaffold.py'
printf '%s\n' mount_policy_source_ok
