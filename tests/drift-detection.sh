#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

fail() {
  echo "drift_detection_failed: $*" >&2
  exit 1
}

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "not in a Git worktree"

if git ls-files agents/private | grep -q .; then
  fail "public repo tracks agents/private"
fi

if git ls-files --cached --others --exclude-standard | grep -Eq '(^|/)(auth\.json|auth\.lock|\.anthropic_oauth\.json|config\.yaml|\.env)$'; then
  fail "public candidate file list contains runtime credential/config state"
fi

if git status --porcelain=v1 --ignored=matching -- agents/private | grep -Ev '^(!! |$)' >/dev/null; then
  fail "agents/private has non-ignored public status"
fi

echo "drift_detection_ok"
