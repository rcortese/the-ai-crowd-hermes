#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

fail() {
  echo "persona_rpc_cutover_failed: $1" >&2
  exit 1
}

COMPOSE=compose.yaml
MOSS_CFG=agents/public/moss/config.example.yaml
RICHMOND_CFG=agents/public/richmond/config.example.yaml
ELDERS_CFG=agents/public/the-elders/config.example.yaml
JEN_API=agents/public/jen/persona-api.example.yaml
DENHOLM_API=agents/public/denholm/persona-api.example.yaml
ROY_API=agents/public/roy/persona-api.example.yaml

PEERS=(jen denholm roy richmond the-elders)

extract_service() {
  # Print the top-level "  <name>:" service block from compose.yaml.
  awk -v svc="  $1:" '
    $0 == svc { in_block=1; print; next }
    in_block && /^  [a-zA-Z0-9_-]+:$/ { exit }
    in_block { print }
  ' "$COMPOSE"
}

# 1. No nats service and no nats_data volume anywhere in compose.yaml.
if grep -Eq '^\s*nats:' "$COMPOSE"; then
  fail "nats service still present in $COMPOSE"
fi
if grep -q 'nats_data' "$COMPOSE"; then
  fail "nats_data volume still referenced in $COMPOSE"
fi
echo "nats_removed_ok"
if grep -Eq '^    build:' "$COMPOSE"; then
  fail "runtime compose must not contain service build paths"
fi
echo "runtime_build_paths_absent_ok"

# 2. Moss all-in-one supervisord requires both owner-policy variables to exist.
# Keep the now-local dispatcher explicitly Moss-owned and fail closed for
# unowned boards. The peer services remain free of all HERMES_KANBAN_* vars.
moss_block="$(extract_service moss)"
echo "$moss_block" | grep -q 'HERMES_KANBAN_DISPATCH_OWNER: "moss"' \
  || fail "moss HERMES_KANBAN_DISPATCH_OWNER must be moss"
echo "$moss_block" | grep -q 'HERMES_KANBAN_DISPATCH_UNOWNED_BOARDS: "false"' \
  || fail "moss HERMES_KANBAN_DISPATCH_UNOWNED_BOARDS must be false"
echo "moss_kanban_supervisor_env_ok"

# 3. Moss localizes its kanban home and dispatches in-gateway.
echo "$moss_block" | grep -q 'HERMES_KANBAN_HOME: /opt/data' || fail "moss HERMES_KANBAN_HOME must be /opt/data"
echo "$moss_block" | grep -Eq "HERMES_KANBAN_DISPATCH_IN_GATEWAY: 'true'" || fail "moss HERMES_KANBAN_DISPATCH_IN_GATEWAY must be true"
echo "moss_kanban_localized_ok"

# 4. Zero HERMES_KANBAN_* env vars for every peer service and touched
# peer runtime config. Kanban dispatch is exclusively Moss-local.
for peer in "${PEERS[@]}"; do
  peer_block="$(extract_service "$peer")"
  if echo "$peer_block" | grep -q 'HERMES_KANBAN_'; then
    fail "peer service $peer must have zero HERMES_KANBAN_* env vars"
  fi
done
for peer_config in "$RICHMOND_CFG" "$ELDERS_CFG" "$JEN_API" "$DENHOLM_API" "$ROY_API"; do
  if grep -q 'HERMES_KANBAN_' "$peer_config"; then
    fail "peer config $peer_config must have zero HERMES_KANBAN_* references"
  fi
done
echo "peer_kanban_env_absent_ok"

# 5. Exact hub persona_api caller/target IDs and credential env-name references.
for peer in "${PEERS[@]}"; do
  grep -q "^      ${peer}:\$" "$MOSS_CFG" || fail "moss persona_api.inbound.callers missing $peer"
  grep -q "^      ${peer}:\$" "$MOSS_CFG" || fail "moss persona_api.outbound.targets missing $peer"
done
grep -q 'self_target: moss' "$MOSS_CFG" || fail "moss persona_api.self_target must be moss"

env_suffix() {
  echo "$1" | tr '[:lower:]-' '[:upper:]_'
}

moss_block_compose="$(extract_service moss)"
for peer in "${PEERS[@]}"; do
  suffix="$(env_suffix "$peer")"
  echo "$moss_block_compose" | grep -q "PERSONA_CALLER_${suffix}_TOKEN: \${${suffix}_TO_MOSS_PERSONA_TOKEN:-}" \
    || fail "moss compose.yaml missing PERSONA_CALLER_${suffix}_TOKEN reference"
  echo "$moss_block_compose" | grep -q "PERSONA_TARGET_${suffix}_TOKEN: \${MOSS_TO_${suffix}_PERSONA_TOKEN:-}" \
    || fail "moss compose.yaml missing PERSONA_TARGET_${suffix}_TOKEN reference"

  peer_block="$(extract_service "$peer")"
  echo "$peer_block" | grep -q "PERSONA_CALLER_MOSS_TOKEN: \${MOSS_TO_${suffix}_PERSONA_TOKEN:-}" \
    || fail "$peer compose.yaml missing PERSONA_CALLER_MOSS_TOKEN reference"
  echo "$peer_block" | grep -q "PERSONA_TARGET_MOSS_TOKEN: \${${suffix}_TO_MOSS_PERSONA_TOKEN:-}" \
    || fail "$peer compose.yaml missing PERSONA_TARGET_MOSS_TOKEN reference"
done

for spec in "richmond:$RICHMOND_CFG" "the-elders:$ELDERS_CFG" "jen:$JEN_API" "denholm:$DENHOLM_API" "roy:$ROY_API"; do
  peer="${spec%%:*}"
  file="${spec#*:}"
  grep -q "self_target: ${peer}" "$file" || fail "$file self_target must be $peer"
  grep -q '^      moss:$' "$file" || fail "$file persona_api must reference moss as caller/target"
  grep -q "allow_targets: \[${peer}\]" "$file" || fail "$file allow_targets must be [$peer]"
  grep -q 'url: http://moss:8648' "$file" || fail "$file outbound target url must be http://moss:8648"
done
echo "persona_api_ids_and_env_refs_ok"

# 6. No secret literal: every *_TOKEN reference in the touched files must be a
# ${VAR:-...} env-var indirection, never an inline literal value.
if grep -nE '^[[:space:]]*token:' "$MOSS_CFG" "$RICHMOND_CFG" "$ELDERS_CFG" "$JEN_API" "$DENHOLM_API" "$ROY_API" | grep -v -F ': ${'; then
  fail "inline token literal found in a config example"
fi
if grep -nE '_TOKEN:' "$COMPOSE" | grep -v -F ': ${'; then
  fail "inline *_TOKEN literal found in $COMPOSE"
fi
echo "no_secret_literal_ok"

# 7. The active public runtime contract must not reintroduce shared-storage
# handoff semantics. Shared storage is permitted only for passive referenced
# artifacts; Persona RPC remains the only interpersona request/response path.
ACTIVE_CONTRACTS=(
  agents/public/jen/AGENTS.md
  agents/public/moss/AGENTS.md
  agents/public/moss/contracts/operating-contract.md
  docs/architecture/agent-container-model.md
  docs/architecture/mounts-and-capabilities.md
  docs/operations/private-mount-boundary.md
  ops/policies/mount-policy.md
  shared/README.md
)
if grep -nEi 'shared handoff|handoff space|handoff material' "${ACTIVE_CONTRACTS[@]}"; then
  fail "shared-storage handoff semantics reintroduced in active contracts"
fi
if find shared -type f -perm /111 -print -quit | grep -q .; then
  fail "shared/ must not publish executable transport or watcher files"
fi
mapfile -d '' ACTIVE_JEN_RUNTIME_FILES < <(
  find agents/public/jen/bin agents/public/jen/lib agents/public/jen/tools/cron-scripts -type f -print0
)
if grep -nEi '/mnt/hermes-shared/handoffs|HANDOFF_(ROOT|MODE)|--handoff-file|handoff_file' "${ACTIVE_JEN_RUNTIME_FILES[@]}"; then
  fail "active Jen executable retains shared-file handoff delivery"
fi
calendar_shared_path_error="$(mktemp)"
if JEN_CRON_STATE_DIR=/mnt/hermes-shared/forbidden \
  agents/public/jen/tools/cron-scripts/jen-calendar-auth-watch.sh >/dev/null 2>"$calendar_shared_path_error"; then
  rm -f "$calendar_shared_path_error"
  fail "calendar auth watch accepted shared state path"
fi
grep -q 'shared_state_path_forbidden' "$calendar_shared_path_error" \
  || fail "calendar auth watch did not fail closed on shared state path"
rm -f "$calendar_shared_path_error"
echo "shared_transport_contract_absent_ok"

echo "persona_rpc_cutover_ok"
