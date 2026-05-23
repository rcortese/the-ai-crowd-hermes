#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
preflight-template.sh --capability <id> --target <description>

Safe no-op template for future Moss wrappers. It verifies that a caller named
an intended capability and target, then prints evidence. It performs no remote,
privileged, destructive, or external action.
USAGE
}

capability=""
target=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --capability)
      capability="${2:-}"
      shift 2
      ;;
    --target)
      target="${2:-}"
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

if [ -z "$capability" ] || [ -z "$target" ]; then
  echo "capability and target are required" >&2
  usage >&2
  exit 2
fi

cat <<EOF
preflight_template_ok=true
capability=$capability
target=$target
action=none
note=template only; no privileged operation executed
EOF
