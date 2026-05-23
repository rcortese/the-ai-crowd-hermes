#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

run() {
  echo "==> $*"
  "$@"
}

run agents/moss/tests/contract-smoke-test.sh
run agents/moss/tools/wrappers/preflight-template.sh --capability project_files --target example-project
run agents/moss/tools/wrappers/workspace-dirty-watch.sh --repo . --label hermes-public-scaffold
run agents/moss/tools/wrappers/messaging-dry-run.sh --channel direct-message --recipient private-ref:operator-direct --message 'public scaffold dry run' --dry-run
run agents/moss/tools/wrappers/ssh-readonly-preflight.sh --host-ref private-ref:private-infra-host --user-ref private-ref:private-infra-user --command-class host-summary --dry-run
run agents/moss/tools/wrappers/compose-readonly-preflight.sh --repo . --mode config --dry-run
run tests/image-pin.sh
run tests/health-check.sh
run tests/drift-detection.sh
run tests/validate-schemas.sh
run tests/release-scan.sh
run tests/private-state-policy.sh
run tests/private-mount-boundary.sh
run tests/cutover-policy.sh
run tests/capability-lanes.sh
if tests/mount-policy.sh; then
  true
else
  status=$?
  if [ "$status" -eq 2 ] && [ "${ALLOW_BLOCKED_OPTIONAL_CHECKS:-0}" = "1" ]; then
    echo "mount_policy_optional_blocked"
  else
    exit "$status"
  fi
fi
run tests/history-scan.sh
run git diff --check
compose_cmd=(docker compose)
if ! docker compose version >/dev/null 2>&1; then
  if command -v docker-compose >/dev/null 2>&1; then
    compose_cmd=(docker-compose)
  elif [ "${ALLOW_BLOCKED_OPTIONAL_CHECKS:-0}" = "1" ]; then
    echo "compose_config_optional_blocked"
    echo "run_all_ok"
    exit 0
  else
    echo 'compose_config_blocked: docker compose is unavailable' >&2
    exit 2
  fi
fi

run "${compose_cmd[@]}" -f compose.yaml config >/dev/null
HERMES_EXAMPLE_PROJECTS_ROOT=/PUBLIC_PLACEHOLDER/projects \
  run "${compose_cmd[@]}" -f compose.yaml -f compose.project-mount.example.yaml config >/dev/null

echo "run_all_ok"
