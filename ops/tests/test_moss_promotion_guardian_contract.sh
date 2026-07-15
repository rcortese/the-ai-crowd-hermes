#!/usr/bin/env bash
# Contract test: source-only fakes prove the guardian fails closed and never
# reintroduces a separate stop lifecycle command.
set -Eeuo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
guardian="$repo/ops/scripts/moss-promotion-guardian.sh"
runner="$repo/ops/scripts/deploy-moss-write-safe-root-candidate.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
[[ -x $guardian ]] || { echo guardian_not_executable >&2; exit 1; }
! grep -Eq 'compose.* stop moss|run_canonical_compose stop' "$guardian" "$runner"
grep -Fq 'up -d --no-deps --force-recreate --wait --wait-timeout 180' "$guardian"
grep -Fq 'setsid "$guardian" --state "$state" --execute' "$runner"
grep -Fq 'health_idle && sleep 5 && health_idle' "$guardian"
grep -Fq 'rollback_ready' "$guardian"
grep -Fq 'guardian CAS mismatch' "$guardian"
mkdir -p "$tmp/state"
for f in candidate-image-id activation-live-image-id activation-candidate-image-id; do printf 'sha256:%064d\n' 1 > "$tmp/state/$f"; done
printf '%s\n' the-ai-crowd-moss-1 > "$tmp/state/activation-container"
printf '%s\n' fake-container > "$tmp/state/activation-container-id"
printf '%s\n' 1111111111111111111111111111111111111111 > "$tmp/state/commit"
mkdir -p "$tmp/fakebin"
printf "%s\n" "#!/usr/bin/env bash" "exit 1" > "$tmp/fakebin/docker"
chmod 0755 "$tmp/fakebin/docker"
if PATH="$tmp/fakebin:$PATH" "$guardian" --state "$tmp/state" --execute >"$tmp/out" 2>&1; then echo guardian_unexpectedly_ran_without_docker >&2; exit 1; fi
grep -Fxq admission_blocked "$tmp/state/status"
echo moss_promotion_guardian_contract_ok
