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
launcher_err=$(mktemp /tmp/hddt-launcher-init.XXXXXX); trap 'rm -f -- "$launcher_err"' EXIT
set +e
"$launcher" 2>"$launcher_err"
launcher_rc=$?
set -e
[[ $launcher_rc == 64 ]] || fail "launcher initialization rc=$launcher_rc: $(<"$launcher_err")"
grep -Fxq 'HDDT launcher: usage: --operation-id ID' "$launcher_err" || fail launcher-initialization-diagnostic
grep -Fq 'DEFAULT_ROOT=/mnt/ssd/appdata/the-ai-crowd-hddt' "$exec" || fail fixed-root
grep -Fq 'DEFAULT_STACK_INPUTS=/mnt/ssd/appdata/the-ai-crowd' "$exec" || fail fixed-stack
for f in "$exec" "$producer"; do grep -Fq 'hddt-moss-closure.sh' "$f" || fail "shared closure not used: $f"; done
for key in source_closure_sha256 builder_sha256 executor_sha256 launcher_sha256; do grep -Fq "$key" "$exec" || fail "executor missing $key"; grep -Fq "$key" "$producer" || fail "producer missing $key"; done
! grep -Fq 'HDDT_NATIVE_ADAPTER' "$exec" || fail native-adapter-reference
! grep -Fq 'automatic' "$exec" || fail automatic-mode-reference
! grep -Fq 'VERIFYING_AUTOMATIC' "$exec" || fail automatic-state-reference
! grep -Fq '/mnt/user/appdata/the-ai-crowd-hddt' "$exec" || fail user-alias-default
grep -Fq 'nohup setsid' "$launcher" || fail detached-launch
grep -Fq -- '--operation-id' "$launcher" || fail launcher-argv
grep -Fq 'HANDSHAKE_SECONDS=30' "$launcher" || fail handshake
for f in runner.launch.json runner.started.json runner.exit.json; do grep -Fq "$f" "$launcher" || fail "missing $f"; done
grep -Fq 'terminal.json' "$exec" || fail terminal-authority
grep -Fq 'RECOVERY_UNRESOLVED' "$exec" || fail unresolved-oracle
grep -Fq 'rendered.json' "$exec" || fail sealed-render-oracle
grep -Fq 'config --no-path-resolution --format json "$SERVICE"' "$exec" || fail service-scoped-render
grep -Fq "'{services:{moss:.services.moss},networks:(.networks//{})}'" "$exec" || fail normalized-render
grep -Fq -- '--project-directory "$DEFAULT_STACK_INPUTS"' "$exec" || fail canonical-apply-project-directory
grep -Fq ': >"$dst/env/roy.env"' "$exec" || fail remote-env-parser-placeholder
! grep -Fq 'cp --reflink=never "$sr/env/roy.env"' "$exec" || fail remote-env-secret-copy
mount_filter='all(.[]; .Source as $s | (($s=="/") or ($s==$r) or ($s|startswith($r+"/")) or ($r|startswith($s+"/")) or ($s==$release) or ($s|startswith($release+"/")) or ($release|startswith($s+"/")) or ($s==$stack) or ($stack|startswith($s+"/")))|not)'
grep -Fq "$mount_filter" "$exec" || fail mount-domain-filter
r=/mnt/ssd/appdata/the-ai-crowd-hddt/state
release=/mnt/ssd/appdata/the-ai-crowd-hddt/release-source
stack=/mnt/ssd/appdata/the-ai-crowd
jq -e --arg r "$r" --arg release "$release" --arg stack "$stack" "$mount_filter" <<<'[{"Source":"/mnt/ssd/appdata/the-ai-crowd/runtime/moss-home"}]' >/dev/null || fail legitimate-stack-descendant-rejected
for unsafe in / "$r" "$r/child" "$(dirname "$r")" "$release" "$release/child" "$(dirname "$release")" "$stack" "$(dirname "$stack")"; do
  if jq -e --arg r "$r" --arg release "$release" --arg stack "$stack" "$mount_filter" <<<"[{\"Source\":\"$unsafe\"}]" >/dev/null; then
    fail "unsafe mount domain accepted: $unsafe"
  fi
done
printf '%s\n' 'hddt-lite-contract: PASS source-stack-separated closure=shared four-hashes=bound followable-only launcher=durable stack-descendants=allowed custody-overlap=blocked'
