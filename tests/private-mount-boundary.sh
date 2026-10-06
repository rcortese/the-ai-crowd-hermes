#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export PYTHONDONTWRITEBYTECODE=1
python3 -m unittest discover -s tests -p 'test_public_scaffold.py'
python3 tests/privacy_guard.py --mode tree
printf '%s\n' private_mount_boundary_ok
