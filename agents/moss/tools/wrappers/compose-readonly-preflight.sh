#!/usr/bin/env bash
set -euo pipefail

repo=""
mode="config"
dry_run=1

usage() {
  cat <<'EOF'
usage: compose-readonly-preflight.sh --repo <path> [--mode config|status] [--dry-run]

Public scaffold wrapper for Docker/Compose capability-lane preflight evidence.
It performs only local read-only checks and never controls a host Docker daemon.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) repo="${2:-}"; shift 2 ;;
    --mode) mode="${2:-}"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    --live|--mutate)
      echo "compose_mutation_blocked: public scaffold wrapper is read-only/dry-run only" >&2
      exit 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$repo" ]; then
  echo "compose_preflight_failed: --repo is required" >&2
  usage >&2
  exit 2
fi

case "$mode" in
  config|status) ;;
  *) echo "compose_preflight_failed: unsupported mode '$mode'" >&2; exit 2 ;;
esac

if [ ! -d "$repo" ]; then
  echo "compose_preflight_failed: repo path does not exist: $repo" >&2
  exit 2
fi

if [ ! -f "$repo/compose.yaml" ] && [ ! -f "$repo/docker-compose.yml" ] && [ ! -f "$repo/docker-compose.yaml" ]; then
  echo "compose_preflight_failed: no compose file found in $repo" >&2
  exit 2
fi

git_state="not-a-git-worktree"
if git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git_state="git-worktree"
fi

printf 'compose_readonly_preflight_ok repo=%s mode=%s git_state=%s host_control=false mutation=false\n' "$repo" "$mode" "$git_state"
