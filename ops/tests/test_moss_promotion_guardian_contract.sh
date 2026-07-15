#!/usr/bin/env bash
set -Eeuo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
guardian="$repo/ops/scripts/moss-promotion-guardian.sh"
runner="$repo/ops/scripts/deploy-moss-write-safe-root-candidate.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
candidate="sha256:$(printf 'a%.0s' {1..64})"
rollback="sha256:$(printf 'b%.0s' {1..64})"
commit=1111111111111111111111111111111111111111
lock=/mnt/user/appdata/the-ai-crowd/state/shared/moss-promotion.lock
had_lock=0; [[ -e $lock ]] && had_lock=1
cleanup_lock() { [[ $had_lock == 1 ]] || rm -f "$lock"; }
trap 'cleanup_lock; rm -rf "$tmp"' EXIT
[[ -x $guardian ]]
! grep -Eq 'compose.* stop moss|run_canonical_compose stop' "$guardian" "$runner"
grep -Fq 'flock -n 9' "$guardian"
grep -Fq 'fence_ingress' "$guardian"
grep -Fq 'admission_blocked:post_fence_activity' "$guardian"
grep -Fq 'guardian_failed:unexpected_exit_' "$guardian"
mkdir -p "$tmp/state" "$tmp/fakebin"
for pair in "candidate-image-id:$candidate" "activation-live-image-id:$rollback" "activation-candidate-image-id:$candidate" "activation-container:the-ai-crowd-moss-1" "activation-container-id:fake-container" "commit:$commit"; do printf '%s\n' "${pair#*:}" > "$tmp/state/${pair%%:*}"; done
cat > "$tmp/fakebin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >> "$FAKE_CALLS"
case "$1 ${2:-}" in
  "exec the-ai-crowd-moss-1") [[ $* == *'/health'* ]] && printf '%s\n' '{"status":"ok","active_streams":0,"active_runs":0}'; exit 0 ;;
  "network disconnect"|"network connect"|"compose --project-directory") exit 0 ;;
  "image tag") if [[ ${FAKE_KILL_GUARDIAN:-0} == 1 ]]; then kill -KILL "$PPID"; exit 0; fi; exit 0 ;;
  "inspect -f") if [[ $3 == *'{{.Id}}|{{.Image}}'* ]]; then printf '%s|%s\n' fake-container "$FAKE_ROLLBACK"; else printf '%s|%s|%s\n' running healthy "$FAKE_CANDIDATE"; fi; exit 0 ;;
  "image inspect") printf '%s\n' "$FAKE_CANDIDATE"; exit 0 ;;
esac
exit 97
DOCKER
printf '%s\n' '#!/usr/bin/env bash' 'printf 401' > "$tmp/fakebin/curl"
chmod 0755 "$tmp/fakebin/docker" "$tmp/fakebin/curl"
: > "$tmp/calls"
FAKE_CALLS="$tmp/calls" FAKE_CANDIDATE="$candidate" FAKE_ROLLBACK="$rollback" PATH="$tmp/fakebin:$PATH" "$guardian" --state "$tmp/state" --execute >/dev/null
[[ $(<"$tmp/state/status") == promote_complete ]]
stop_line=$(grep -n 'supervisorctl.*stop moss-gateway' "$tmp/calls" | cut -d: -f1); fence_line=$(grep -n 'network disconnect network_default' "$tmp/calls" | cut -d: -f1); up_line=$(grep -n 'compose .* up -d --no-deps --force-recreate --wait --wait-timeout 180 moss' "$tmp/calls" | cut -d: -f1)
[[ $stop_line -lt $fence_line && $fence_line -lt $up_line ]]
! grep -q ' stop moss' "$tmp/calls"
mkdir -p "$tmp/missing"
set +e; PATH="$tmp/fakebin:$PATH" "$guardian" --state "$tmp/missing" --execute >/dev/null 2>&1; rc=$?; set -e
[[ $rc == 1 && $(<"$tmp/missing/status") == guardian_failed:missing_evidence_candidate-image-id ]]
# Lock contention aborts before even the initial health observation.
: > "$lock"
flock -x "$lock" sleep 3 & holder=$!
sleep 0.1
: > "$tmp/calls"
set +e; FAKE_CALLS="$tmp/calls" FAKE_CANDIDATE="$candidate" FAKE_ROLLBACK="$rollback" PATH="$tmp/fakebin:$PATH" "$guardian" --state "$tmp/state" --execute >/dev/null 2>&1; rc=$?; set -e
wait "$holder"
[[ $rc == 2 && $(<"$tmp/state/status") == lifecycle_lock_busy && ! -s $tmp/calls ]]
# A non-trappable death after the first mutation intent leaves an explicit, durable
# recovery-required receipt rather than the ambiguous old `activating` state.
set +e
FAKE_CALLS="$tmp/calls" FAKE_CANDIDATE="$candidate" FAKE_ROLLBACK="$rollback" FAKE_KILL_GUARDIAN=1 PATH="$tmp/fakebin:$PATH" "$guardian" --state "$tmp/state" --execute >/dev/null 2>&1
rc=$?
set -e
[[ $rc -eq 137 && $(<"$tmp/state/status") == activation_uncertain ]]
echo moss_promotion_guardian_contract_ok
