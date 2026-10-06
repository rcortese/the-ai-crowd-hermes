#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export PYTHONDONTWRITEBYTECODE=1
python3 -m unittest discover -s tests -p 'test_privacy_guard.py' -v
python3 -m unittest discover -s tests -p 'test_public_scaffold.py' -v
python3 -m unittest discover -s ops/tests -p 'test_runtime_backup_retention.py' -v
bash agents/public/moss/tests/contract-smoke-test.sh
command -v jq >/dev/null
for contract in self-heal capture write-safety-gate interaction-loop; do
  bash "agents/public/jen/tests/jen-todoist-$contract.contract.sh"
done
python3 tests/privacy_guard.py --mode tree
git diff --check
printf '%s\n' offline_suite_ok
