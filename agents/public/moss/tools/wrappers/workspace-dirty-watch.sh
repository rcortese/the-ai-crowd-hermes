#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
workspace-dirty-watch.sh --repo <path> --label <id>

Read-only Git workspace inspection for automation checks.
It prints kanban-friendly evidence and performs no fetch, commit, push,
notification, remote command, or file write.
USAGE
}

repo=""
label=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      repo="${2:-}"
      shift 2
      ;;
    --label)
      label="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ -z "$repo" ] || [ -z "$label" ]; then
  echo "repo and label are required" >&2
  usage >&2
  exit 2
fi

case "$label" in
  *[!a-zA-Z0-9_.-]*|"")
    echo "label must contain only letters, numbers, dot, underscore, or dash" >&2
    exit 2
    ;;
esac

if [ ! -d "$repo" ]; then
  echo "repo path does not exist or is not a directory: $repo" >&2
  exit 2
fi

if ! git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "target is not a Git worktree: $repo" >&2
  exit 2
fi

worktree_root="$(git -C "$repo" rev-parse --show-toplevel)"
branch="$(git -C "$repo" symbolic-ref --quiet --short HEAD 2>/dev/null || echo detached)"
head_sha="$(git -C "$repo" rev-parse --short=12 HEAD)"
upstream="$(git -C "$repo" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || echo none)"
status_lines="$(git -C "$repo" status --short --untracked-files=normal)"
if [ -n "$status_lines" ]; then
  dirty="true"
  status_count="$(printf '%s\n' "$status_lines" | wc -l | tr -d ' ')"
else
  dirty="false"
  status_count="0"
fi

cat <<EOF
workspace_dirty_watch_ok=true
label=$label
repo_root=$worktree_root
branch=$branch
head=$head_sha
upstream=$upstream
dirty=$dirty
status_count=$status_count
delivery=local-evidence-only
action=none
mutation=none
EOF
