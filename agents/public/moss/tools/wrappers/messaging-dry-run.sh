#!/usr/bin/env bash
set -euo pipefail

channel=""
recipient=""
message=""
dry_run=1

usage() {
  cat <<'EOF'
usage: messaging-dry-run.sh --channel <name> --recipient <private-ref|placeholder> --message <text> [--dry-run]

Public scaffold wrapper for external messaging evidence. It never sends live messages.
Live messaging requires a private wrapper, private credentials, recipient policy, disable switch, review gate, and authorized smoke.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --channel) channel="${2:-}"; shift 2 ;;
    --recipient) recipient="${2:-}"; shift 2 ;;
    --message) message="${2:-}"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    --live)
      echo "messaging_live_blocked: public scaffold wrapper is dry-run only" >&2
      exit 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$channel" ] || [ -z "$recipient" ] || [ -z "$message" ]; then
  echo "messaging_preflight_failed: --channel, --recipient, and --message are required" >&2
  usage >&2
  exit 2
fi

case "$channel" in
  direct-message|email|signal|webhook) ;;
  *) echo "messaging_preflight_failed: unsupported public-scaffold channel '$channel'" >&2; exit 2 ;;
esac

case "$recipient" in
  private-ref:*|placeholder:*|example:*) ;;
  *) echo "messaging_preflight_failed: recipient must be a private-ref or placeholder in public scaffold" >&2; exit 2 ;;
esac

if printf '%s\n%s\n' "$recipient" "$message" | grep -E '(token=|Bearer |BEGIN [A-Z ]*PRIVATE KEY|[0-9]{3}\.[0-9]{3}\.[0-9]{3}-[0-9]{2})' >/dev/null; then
  echo "messaging_preflight_failed: message or recipient appears to contain sensitive material" >&2
  exit 2
fi

printf 'messaging_dry_run_ok channel=%s recipient_ref=%s chars=%s live_send=false\n' "$channel" "$recipient" "${#message}"
