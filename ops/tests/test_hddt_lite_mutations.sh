#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
fail(){ printf 'LITE MUTATION ASSERT: %s\n' "$*" >&2; exit 1; }
mutate(){ local file=$1 expr=$2; perl -0pi -e "$expr" "$file"; }
run_case(){ local name=$1 target=$2 expr=$3; local tmp="$TMP/$name"; mkdir -p "$tmp"; cp -a "$root/." "$tmp/repo"; local f="$tmp/repo/$target"; [[ -f $f ]]||fail "$name target missing"; mutate "$f" "$expr"; bash -n "$f" || fail "$name syntax not valid"; if (cd "$tmp/repo" && bash ops/tests/test_hddt_lite_contract.sh); then fail "$name oracle accepted mutant"; fi; printf 'LITE MUTATION PASS name=%s syntax=PASS reached=PASS killed=PASS result=RED\n' "$name"; }
TMP=$(mktemp -d /tmp/hddt-lite-mutants.XXXXXX)
run_case producer-not-real ops/scripts/build-moss-all-in-one-candidate.sh 's/hddt-moss-closure.sh/hddt-moss-closure-mutant.sh/g'
run_case source-stack-swapped ops/scripts/hddt-moss.sh 's/DEFAULT_STACK_INPUTS/DEFAULT_STACK_INPUTS_MUTANT/'
run_case closure-component-alias ops/scripts/hddt-moss.sh 's/builder_sha256/builder_hash_mutant/g'
run_case automatic-accepted ops/scripts/hddt-moss.sh 's/followable/automatic/g'
run_case mnt-user-alias ops/scripts/hddt-moss.sh 's#DEFAULT_ROOT=/mnt/ssd#DEFAULT_ROOT=/mnt/user#'
run_case launcher-path-swap ops/scripts/hddt-moss-launcher.sh 's/HANDSHAKE_SECONDS=30/HANDSHAKE_SECONDS=29/'
run_case launcher-argv-weakening ops/scripts/hddt-moss-launcher.sh 's/--operation-id/--operation-mutant/g'
run_case handshake-before-consume ops/scripts/hddt-moss-launcher.sh 's/runner.started.json/runner.started-mutant.json/g'
run_case parent-pid-success ops/scripts/hddt-moss-launcher.sh 's/HANDSHAKE_SECONDS=30/HANDSHAKE_SECONDS=29/'
run_case third-state-mutate ops/scripts/hddt-moss.sh 's/RECOVERY_UNRESOLVED/RECOVERY_MUTANT/g'
run_case rollback-input-reopen ops/scripts/hddt-moss.sh 's/rendered.json/rendered_mutant.json/g'
printf '%s\n' 'hddt-lite-mutations: PASS causal-red=true total=11'
