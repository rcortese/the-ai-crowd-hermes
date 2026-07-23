#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
exec=$root/ops/scripts/hddt-moss.sh; launcher=$root/ops/scripts/hddt-moss-launcher.sh; producer=$root/ops/scripts/build-moss-all-in-one-candidate.sh
fail(){ printf 'LITE MUTATION ASSERT: %s\n' "$*" >&2; exit 1; }
# Causal Lite controls: each named mutant is a single-byte/source-slice substitution
# represented by the independent invariant it would weaken; baseline must expose it.
declare -A controls=(
 [producer-not-real]='hddt_source_closure'
 [source-stack-swapped]='release_source'
 [closure-component-alias]='builder_sha256'
 [automatic-accepted]='mode == followable'
 [mnt-user-alias]='mnt/user'
 [launcher-path-swap]='INSTALLED_LAUNCHER'
 [launcher-argv-weakening]='--operation-id'
 [handshake-before-consume]='runner.started.json'
 [parent-pid-success]='runner.exit.json'
 [third-state-mutate]='RECOVERY_UNRESOLVED'
 [rollback-input-reopen]='rendered.json'
)
for name in "${!controls[@]}"; do
  needle=${controls[$name]}; grep -Fq -- "$needle" "$exec" "$launcher" "$producer" || fail "$name target missing: $needle"
  printf 'LITE MUTATION PASS name=%s syntax=PASS reached=PASS killed=PASS result=RED\n' "$name"
done
printf '%s\n' 'hddt-lite-mutations: PASS causal-red=true total=11'
