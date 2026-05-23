#!/usr/bin/env bash
set -euo pipefail

host_ref=""
user_ref=""
command_class="host-summary"
dry_run=1

usage() {
  cat <<'EOF'
usage: ssh-readonly-preflight.sh --host-ref <private-ref|placeholder> --user-ref <private-ref|placeholder> [--command-class <class>] [--dry-run]

Public scaffold wrapper for private-host SSH preflight evidence. It does not connect to hosts.
Live SSH requires a private wrapper, private SSH material, allowed host/user policy, review gate, and validation evidence.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --host-ref) host_ref="${2:-}"; shift 2 ;;
    --user-ref) user_ref="${2:-}"; shift 2 ;;
    --command-class) command_class="${2:-}"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    --live)
      echo "ssh_live_blocked: public scaffold wrapper is dry-run only" >&2
      exit 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$host_ref" ] || [ -z "$user_ref" ]; then
  echo "ssh_preflight_failed: --host-ref and --user-ref are required" >&2
  usage >&2
  exit 2
fi

for ref in "$host_ref" "$user_ref"; do
  case "$ref" in
    private-ref:*|placeholder:*|example:*) ;;
    *) echo "ssh_preflight_failed: refs must be private-ref or placeholder values" >&2; exit 2 ;;
  esac
done

case "$command_class" in
  host-summary|disk-readonly|service-readonly|compose-readonly) ;;
  *) echo "ssh_preflight_failed: unsupported command class '$command_class'" >&2; exit 2 ;;
esac

printf 'ssh_readonly_preflight_ok host_ref=%s user_ref=%s command_class=%s live_connect=false\n' "$host_ref" "$user_ref" "$command_class"
