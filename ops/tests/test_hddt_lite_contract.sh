#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
exec=$root/ops/scripts/hddt-moss.sh
producer=$root/ops/scripts/build-moss-all-in-one-candidate.sh
launcher=$root/ops/scripts/hddt-moss-launcher.sh
closure=$root/ops/scripts/lib/hddt-moss-closure.sh
fail(){ printf 'LITE CONTRACT: %s\n' "$*" >&2; exit 1; }
for f in "$exec" "$producer" "$launcher" "$closure"; do [[ -x $f ]] || fail "missing executable $f"; done
bash -n "$exec" "$producer" "$launcher" "$closure"
grep -Fq 'DEFAULT_ROOT=/mnt/ssd/appdata/the-ai-crowd-hddt' "$exec" || fail fixed-root
grep -Fq 'DEFAULT_STACK_INPUTS=/mnt/ssd/appdata/the-ai-crowd' "$exec" || fail fixed-stack
for f in "$exec" "$producer"; do grep -Fq 'hddt-moss-closure.sh' "$f" || fail "shared closure not used: $f"; done
for key in source_closure_sha256 builder_sha256 executor_sha256 launcher_sha256; do grep -Fq "$key" "$exec" || fail "executor missing $key"; grep -Fq "$key" "$producer" || fail "producer missing $key"; done
! grep -Fq 'HDDT_NATIVE_ADAPTER' "$exec" || fail native-adapter-reference
! grep -Fq 'VERIFYING_AUTOMATIC' "$exec" || fail automatic-state-reference
! grep -Fq '/mnt/user/appdata/the-ai-crowd-hddt' "$exec" || fail user-alias-default
grep -Fq 'nohup setsid' "$launcher" || fail detached-launch
grep -Fq 'HANDSHAKE_SECONDS=30' "$launcher" || fail handshake
for f in runner.launch.json runner.started.json runner.exit.json; do grep -Fq "$f" "$launcher" || fail "missing $f"; done
grep -Fq 'terminal.json' "$exec" || fail terminal-authority
printf '%s\n' 'hddt-lite-contract: PASS source-stack-separated closure=shared four-hashes=bound followable-only launcher=durable'
