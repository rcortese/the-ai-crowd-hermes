#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

scan_ref() {
  local ref="$1"
  git grep -n -I -E \
    -e '(^|[^A-Za-z0-9_./-])/home/[a-z_][a-z0-9_-]*(/|$)' \
    -e '(^|[^A-Za-z0-9_.-])(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.)[0-9]{1,3}\.[0-9]{1,3}\b' \
    -e "['\"][0-9]{1,3}\.[0-9]{1,3}\.['\"]" \
    -e '(^|[^A-Za-z0-9_.-])[A-Za-z0-9-]+\.lan\b' \
    -e '(^|[^A-Za-z0-9_./-])/(mnt|media|srv)/(user|disk[0-9]+|cache|ssd|private|secrets)(/|$)' \
    -e '(^|[^A-Za-z0-9_-])[Uu]nraid([^A-Za-z0-9_-]|$)' \
    -e '-----BEGIN (OPENSSH|RSA|EC|DSA|PRIVATE) KEY-----' \
    "$ref" -- .
}

failures=0
if scan_ref HEAD; then
  failures=1
fi

while IFS= read -r rev; do
  if scan_ref "$rev"; then
    failures=1
  fi
done < <(git rev-list --all)

if [[ "$failures" -ne 0 ]]; then
  echo "history_scan_failed"
  exit 1
fi

echo "history_scan_ok"
