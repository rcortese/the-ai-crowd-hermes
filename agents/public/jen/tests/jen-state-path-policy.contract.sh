#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
jen_root="$repo_root/agents/public/jen"
forbidden=/mnt/hermes-shared/jen-state-path-policy-test

expect_blocked() {
  local label="$1"
  shift
  local output rc
  set +e
  output="$("$@" 2>&1)"
  rc=$?
  set -e
  if [[ $rc -eq 0 ]] || ! grep -q 'shared_state_path_forbidden' <<<"$output"; then
    printf 'jen_state_path_policy_failed: %s rc=%s output=%s\n' "$label" "$rc" "$output" >&2
    exit 1
  fi
}

# Central helpers reject the exact root, descendants, and an existing symlink
# that resolves into the shared mount while accepting ordinary local state.
# shellcheck source=../lib/jen-path-policy.sh
source "$jen_root/lib/jen-path-policy.sh"
[[ "$(jen_require_local_state_path /tmp/jen-local-state)" == /tmp/jen-local-state ]]
expect_blocked shell-root jen_require_local_state_path /mnt/hermes-shared
expect_blocked shell-child jen_require_local_state_path "$forbidden"
link_dir="$(mktemp -d)"
trap 'rm -rf "$link_dir"' EXIT
ln -s /mnt/hermes-shared "$link_dir/shared"
expect_blocked shell-symlink jen_require_local_state_path "$link_dir/shared/child"

expect_blocked calendar-auth env JEN_CRON_STATE_DIR="$forbidden" "$jen_root/tools/cron-scripts/jen-calendar-auth-watch.sh"
expect_blocked calendar-facade env JEN_CRON_STATE_DIR="$forbidden" "$jen_root/tools/cron-scripts/jen-calendar-facade-watch.sh"
expect_blocked recurring env JEN_MORNING_RECURRING_STATE_DIR="$forbidden" "$jen_root/tools/cron-scripts/jen-morning-recurring-maintenance-reanchor.sh"
expect_blocked soft-due env JEN_MORNING_SOFT_DUE_STATE_DIR="$forbidden" "$jen_root/tools/cron-scripts/jen-morning-soft-due-hygiene.sh"
expect_blocked due-adjust env JEN_MORNING_DUE_ADJUST_AUDIT_DIR="$forbidden" "$jen_root/bin/jen-morning-due-adjust" --dry-run
expect_blocked task-runtime env JEN_TASK_RUNTIME_STATE_FILE="$forbidden/state.json" "$jen_root/bin/jen-task-runtime" health
expect_blocked task-observation env JEN_TODOIST_OBSERVATION_STATE_FILE="$forbidden/observation.json" "$jen_root/bin/jen-task-runtime" health
expect_blocked self-heal "$jen_root/bin/jen-todoist-self-heal" health --state-file "$forbidden/self-heal.json"
expect_blocked idempotency "$jen_root/bin/jen-idempotency-store" --dir "$forbidden/idempotency" check --kind message --key test --normalized-hash test

# Discover direct configurable state consumers and require each to bind the
# central path policy. This fails when a new sibling adds a state destination
# without joining the common guard.
mapfile -t consumers < <(
  grep -RIlE \
    '(^|[[:space:]])(STATE_DIR|STATE_FILE|OBSERVATION_STATE_FILE|AUDIT_DIR|IDEMPOTENCY_DIR|recurring_state_dir)=.*JEN_|DEFAULT_DIR = Path\(os\.environ\.get\("JEN_|add_argument\("--state-file"' \
    "$jen_root/bin" "$jen_root/tools/cron-scripts"
)
[[ ${#consumers[@]} -gt 0 ]]
for consumer in "${consumers[@]}"; do
  grep -Eq 'jen-path-policy\.sh|jen_path_policy' "$consumer" || {
    echo "jen_state_path_policy_failed: unguarded consumer $consumer" >&2
    exit 1
  }
done

printf 'jen_state_path_policy_ok consumers=%s\n' "${#consumers[@]}"
