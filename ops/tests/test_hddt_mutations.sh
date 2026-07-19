#!/usr/bin/env bash
# Causal sensitivity: each mutation is a private copy and must make the
# behavioural harness RED. No source, Docker daemon, or lifecycle is touched.
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
base="$root/ops/scripts/hddt-moss.sh"
tmp=$(mktemp -d /tmp/hddt-mutation.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
mutate() {
  local id from to copy content
  id=$1; from=$2; to=$3; copy="$tmp/$id.sh"
  cp "$base" "$copy"; chmod +x "$copy"
  content=$(<"$copy"); [[ $content == *"$from"* ]] || { printf 'missing mutation anchor: %s\n' "$from" >&2; exit 1; }
  content=${content/"$from"/"$to"}
  printf '%s' "$content" >"$copy"
  if HDDT_SCRIPT="$copy" bash "$root/ops/tests/test_hddt_moss.sh" >/dev/null 2>&1; then
    printf 'mutation %s was not detected\n' "$id" >&2; exit 1
  fi
  printf 'MUTATION %s RED\n' "$id"
}
mutate argv '--no-build --no-deps --force-recreate' '--no-deps --force-recreate'
mutate authorization '&& $expiry -ge $(now)' '&& $expiry -le $(now)'
mutate health '"health":"healthy"' '"health":"none"'
mutate recovery 'terminal "$op" RECOVERY_UNRESOLVED third_state' 'terminal "$op" SUCCEEDED third_state'
printf '%s\n' 'hddt-mutations: 4/4 RED'
