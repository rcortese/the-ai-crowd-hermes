#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
t="$(mktemp -d)"
trap 'rm -rf "$t"' EXIT
for agent in denholm jen moss richmond roy the-elders unexpected; do
  mkdir -p "$t/agents/public/$agent" "$t/agents/private/$agent" "$t/runtime/$agent-home"
  touch "$t/agents/public/$agent/file"
done
"$ROOT/ops/repair-agent-permissions.sh" --root "$t" --all >"$t/out"
if grep -Fq 'agent=unexpected' "$t/out"; then
  echo 'unexpected public directory was selected by --all' >&2
  exit 1
fi
for agent in denholm jen moss richmond roy the-elders; do
  grep -Fq "agent=$agent" "$t/out" || { echo "missing fixed agent $agent" >&2; exit 1; }
done
echo repair_agent_permissions_contract_ok
# A correct inode must not be touched by --apply; this keeps repair proportional.
t2="$(mktemp -d)"
trap 'rm -rf "$t" "$t2"' EXIT
mkdir -p "$t2/agents/public/denholm" "$t2/agents/private/denholm" "$t2/runtime/denholm-home"
touch "$t2/agents/private/denholm/correct" "$t2/agents/private/denholm/drift"
chown 99:100 "$t2/agents/private/denholm/correct"
correct_before="$(stat -c %Z "$t2/agents/private/denholm/correct")"
sleep 1
"$ROOT/ops/repair-agent-permissions.sh" --root "$t2" --apply --agent denholm >/dev/null
correct_after="$(stat -c %Z "$t2/agents/private/denholm/correct")"
[ "$correct_before" = "$correct_after" ] || { echo 'correct inode was touched by repair' >&2; exit 1; }
[ "$(stat -c %u:%g "$t2/agents/private/denholm/drift")" = '99:100' ] || { echo 'drift inode not repaired' >&2; exit 1; }
echo repair_agent_permissions_proportional_apply_ok
# A non-script fixture under tests must retain its non-executable mode.
t3="$(mktemp -d)"
trap 'rm -rf "$t" "$t2" "$t3"' EXIT
mkdir -p "$t3/agents/public/denholm/tests/fixtures" "$t3/agents/private/denholm" "$t3/runtime/denholm-home"
printf '{}' > "$t3/agents/public/denholm/tests/fixtures/data.json"
chmod 0644 "$t3/agents/public/denholm/tests/fixtures/data.json"
"$ROOT/ops/repair-agent-permissions.sh" --root "$t3" --apply --agent denholm >/dev/null
[ "$(stat -c %a "$t3/agents/public/denholm/tests/fixtures/data.json")" = 644 ] || { echo 'non-script fixture became executable' >&2; exit 1; }
echo repair_agent_permissions_fixture_mode_ok
