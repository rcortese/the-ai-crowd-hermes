#!/usr/bin/env bash
# Source-only contract: every Moss supervisor child that can initiate a remote
# persona route inherits API_SERVER_KEY from the container environment.
set -Eeuo pipefail
root=${1:?candidate source root required}
config="$root/ops/supervisor/moss-all-in-one-supervisord.conf"
fail(){ printf 'moss-supervisor-api-key-contract: RED %s\n' "$*" >&2; exit 1; }
[[ -f $config && ! -L $config ]] || fail 'supervisor config unavailable'

for program in moss-gateway moss-dashboard moss-webui; do
  block=$(awk -v program="$program" '
    $0 == "[program:" program "]" { in_block=1 }
    in_block { print }
    in_block && NR > 1 && /^\[program:/ && $0 != "[program:" program "]" { exit }
  ' "$config")
  [[ $block == *'API_SERVER_KEY="%(ENV_API_SERVER_KEY)s"'* ]] || fail "$program does not inherit API_SERVER_KEY"
done

printf '%s\n' 'moss-supervisor-api-key-contract: PASS programs=3 api-key-inheritance=true'
