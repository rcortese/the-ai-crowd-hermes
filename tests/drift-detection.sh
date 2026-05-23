#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

fail() {
  echo "drift_detection_failed: $*" >&2
  exit 1
}

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  fail "not in a Git worktree"
fi

if git ls-files --error-unmatch agents/moss/private >/dev/null 2>&1; then
  fail "public repo tracks agents/moss/private"
fi

if git ls-files --cached --others --exclude-standard | grep -Eq '(^|/)(auth\.json|auth\.lock|\.anthropic_oauth\.json|config\.yaml|\.env)$'; then
  fail "public candidate file list contains runtime credential/config state"
fi

if git status --porcelain=v1 --ignored=matching -- agents/moss/private | grep -Ev '^(!! |$)' >/dev/null; then
  fail "agents/moss/private has non-ignored public status"
fi

if [ -d agents/moss/private ]; then
  if [ ! -d agents/moss/private/.git ]; then
    fail "agents/moss/private exists but is not a nested Git repo"
  fi
  if git -C agents/moss/private remote | grep -q .; then
    fail "agents/moss/private has a remote configured during scaffold hardening"
  fi
fi

echo "drift_detection_ok"
