#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: repair-agent-permissions.sh [--apply] [--agent NAME|--all] [--root STACK_DIR]

Audits or repairs common The AI Crowd Hermes ownership drift on the Docker host.
Default is dry-run. Expected runtime owner is UID:GID 99:100.

Examples:
  ops/repair-agent-permissions.sh --agent jen
  ops/repair-agent-permissions.sh --apply --agent jen
  ops/repair-agent-permissions.sh --apply --all
USAGE
}

APPLY=0
AGENT=""
ALL=0
ROOT="${ROOT:-}"
UID_EXPECTED="99"
GID_EXPECTED="100"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --agent) shift; AGENT="${1:-}" ;;
    --all) ALL=1 ;;
    --root) shift; ROOT="${1:-}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift || true
done

if [ "$ALL" -eq 0 ] && [ -z "$AGENT" ]; then
  echo "error: provide --agent NAME or --all" >&2
  exit 2
fi
if [ "$ALL" -eq 1 ] && [ -n "$AGENT" ]; then
  echo "error: use either --agent NAME or --all, not both" >&2
  exit 2
fi
: "${ROOT:?set ROOT to the stack root}"
if [ ! -d "$ROOT" ]; then
  echo "error: stack root not found: $ROOT" >&2
  exit 1
fi

log() { printf '[permfix] %s\n' "$*"; }
count_drift() {
  local path="$1"
  [ -e "$path" ] || { echo 0; return; }
  find "$path" -xdev \( ! -user "$UID_EXPECTED" -o ! -group "$GID_EXPECTED" \) -print 2>/dev/null | wc -l
}
show_sample() {
  local path="$1"
  [ -e "$path" ] || return 0
  find "$path" -xdev \( ! -user "$UID_EXPECTED" -o ! -group "$GID_EXPECTED" \) \
    -printf '%u:%g %m %p\n' 2>/dev/null | head -30 || true
}
repair_tree_owner() {
  local path="$1"
  [ -e "$path" ] || return 0
  if [ "$APPLY" -eq 1 ]; then
    find "$path" -xdev \( ! -user "$UID_EXPECTED" -o ! -group "$GID_EXPECTED" \)       -exec chown -h "$UID_EXPECTED:$GID_EXPECTED" {} +
  fi
}
repair_agent() {
  local agent="$1"
  local public="$ROOT/agents/public/$agent"
  local private="$ROOT/agents/private/$agent"
  local home="$ROOT/runtime/${agent}-home"

  log "agent=$agent"
  for p in "$public" "$private" "$home"; do
    if [ -e "$p" ]; then
      stat -c '[permfix] before %u:%g %a %n' "$p"
      local c
      c=$(count_drift "$p")
      log "drift_count=$c path=$p"
      if [ "$c" != "0" ]; then show_sample "$p"; fi
    else
      log "missing path=$p"
    fi
  done

  # Source/runtime trees should be owned by the Hermes runtime UID/GID on the host.
  # chown preserves restrictive modes on secrets such as .env/auth files; chmod below is narrow.
  repair_tree_owner "$public"
  repair_tree_owner "$private"
  repair_tree_owner "$home"

  if [ "$APPLY" -eq 1 ]; then
    [ -d "$home" ] && chmod 0700 "$home" || true
    [ -d "$home/cron" ] && chmod 0700 "$home/cron" || true
    [ -d "$home/cron/output" ] && chmod 0700 "$home/cron/output" || true
    # Public source content should be readable/traversable; scripts keep execute bits if already set.
    if [ -d "$public" ]; then
      find "$public" -type d -exec chmod u+rwx,g+rx,o+rx {} +
      find "$public" -type f -exec chmod u+rw,g+r,o+r {} +
      find "$public" -type f \( -path '*/bin/*' -o -path '*/tools/cron-scripts/*' -o -name '*.sh' \) -exec chmod u+rwx,g+rx,o+rx {} +
    fi
  fi

  for p in "$public" "$private" "$home"; do
    [ -e "$p" ] || continue
    local c
    c=$(count_drift "$p")
    log "after_drift_count=$c path=$p"
  done
}


if [ "$ALL" -eq 1 ]; then
  for agent in denholm jen moss richmond roy the-elders; do
    repair_agent "$agent"
  done
else
  repair_agent "$AGENT"
fi

if [ "$APPLY" -eq 1 ]; then
  log "mode=apply complete"
else
  log "mode=dry-run; no changes made"
fi
