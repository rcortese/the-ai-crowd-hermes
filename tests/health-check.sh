#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export PYTHONDONTWRITEBYTECODE=1
python3 -m unittest discover -s tests -p 'test_public_scaffold.py'
printf '%s\n' scaffold_structure_ok
