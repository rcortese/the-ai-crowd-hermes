#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
mode=fixture
fixture_root=
container=the-ai-crowd-moss-1
skill_path=/opt/data/skills/autonomous-ai-agents/autonomous-ai-agents/SKILL.md
self_test=0

fail() {
  printf 'lean-agent-contracts: RED %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
usage: test_lean_agent_deployment_contracts.sh [--mode fixture|live]
       [--repo-root PATH] [--fixture-root PATH] [--container NAME]
       [--skill-path PATH] [--self-test]

fixture mode is offline and never calls Docker. live mode performs only docker
inspect/exec reads against an already-running container; it does not build,
start, stop, or recreate anything.
EOF
}

while (($#)); do
  case "$1" in
    --mode) mode=${2:?}; shift 2 ;;
    --repo-root) root=${2:?}; shift 2 ;;
    --fixture-root) fixture_root=${2:?}; shift 2 ;;
    --container) container=${2:?}; shift 2 ;;
    --skill-path) skill_path=${2:?}; shift 2 ;;
    --self-test) self_test=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[[ $mode == fixture || $mode == live ]] || fail "invalid mode: $mode"
fixture_root=${fixture_root:-$root/ops/tests/fixtures/lean-agent-contracts}

require_literal() {
  local file=$1 literal=$2 label=$3
  [[ -f $file ]] || fail "$label missing file: $file"
  grep -Fq -- "$literal" "$file" || fail "$label missing: $literal"
}

check_dockerfiles() {
  local persona file last_user
  for persona in moss jen denholm richmond roy the-elders; do
    file=$root/ops/images/Dockerfile.$persona
    [[ -f $file ]] || fail "identity missing Dockerfile.$persona"
    require_literal "$file" 'groupmod -o -g 100 hermes' "identity Dockerfile.$persona"
    require_literal "$file" 'usermod -o -u 99 -g hermes hermes' "identity Dockerfile.$persona"
    require_literal "$file" 'test "$(id -u hermes)" = 99' "identity Dockerfile.$persona"
    require_literal "$file" 'test "$(id -g hermes)" = 100' "identity Dockerfile.$persona"
    require_literal "$file" 'test "$(getent group hermes | cut -d: -f3)" = 100' "identity Dockerfile.$persona"
    require_literal "$file" 'for path in /opt/hermes/.venv /opt/hermes/ui-tui /opt/hermes/skills /opt/hermes/docker; do' "identity Dockerfile.$persona"
    require_literal "$file" 'chown -R hermes:hermes "$path"' "identity Dockerfile.$persona"
    if grep -Fq 'USER 99:100' "$file"; then
      fail "identity Dockerfile.$persona runs bootstrap as 99:100"
    fi
    if grep -Fq '|| true' "$file"; then
      fail "identity Dockerfile.$persona masks a failure"
    fi
    last_user=$(awk '/^USER[[:space:]]/{line=$0} END{print line}' "$file")
    [[ $last_user == 'USER root' ]] || fail "identity Dockerfile.$persona final USER is not root"
  done
  local compose=$root/compose.yaml
  require_literal "$compose" 'supervisors drop workloads' 'identity compose contract'
  require_literal "$compose" 'to the named `hermes` account baked downstream as UID:GID 99:100.' 'identity compose contract'
  require_literal "$compose" 'HERMES_UID/HERMES_GID mirror that identity; they do not perform the remap.' 'identity compose contract'
  printf '%s\n' 'lean-agent-contracts: identity PASS personas=6 uid=99 gid=100 bootstrap=root'
}

read_fixture_env() {
  local env_file=$1 line key value
  lazy_disable=
  lazy_target=
  [[ -f $env_file ]] || fail "lazy missing env fixture: $env_file"
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -z $line || $line == \#* ]] && continue
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      HERMES_DISABLE_LAZY_INSTALLS) lazy_disable=$value ;;
      HERMES_LAZY_INSTALL_TARGET) lazy_target=$value ;;
      *) fail "lazy unsupported fixture env key: $key" ;;
    esac
  done <"$env_file"
}

read_fixture_allow() {
  local config=$1
  [[ -f $config ]] || fail "lazy missing config fixture: $config"
  lazy_allow=$(awk '
    /^[[:space:]]*allow_lazy_installs:[[:space:]]*/ {
      value=$0; sub(/^.*allow_lazy_installs:[[:space:]]*/, "", value);
      sub(/[[:space:]#].*$/, "", value); print value; found=1
    }
    END { if (!found) exit 1 }
  ' "$config") || fail "lazy config lacks security.allow_lazy_installs"
  [[ $lazy_allow == true || $lazy_allow == false ]] || fail "lazy config value must be true or false"
}

assert_lazy_policy() {
  local target_path=$1 expected_policy=$2 expected_ready=$3 label=$4
  local policy=false ready=false target_configured=false target_exists=false target_writable=false
  [[ -n $lazy_target ]] && target_configured=true
  if [[ $lazy_allow == true && ( $lazy_disable != 1 || $target_configured == true ) ]]; then
    policy=true
  fi
  if [[ -n $target_path && -d $target_path ]]; then target_exists=true; fi
  if [[ -n $target_path && -w $target_path ]]; then target_writable=true; fi
  if [[ $policy == true && ( $target_configured == false || ( $target_exists == true && $target_writable == true ) ) ]]; then
    ready=true
  fi
  [[ $policy == "$expected_policy" ]] || fail "lazy $label policy=$policy expected=$expected_policy"
  [[ $ready == "$expected_ready" ]] || fail "lazy $label ready=$ready expected=$expected_ready"
  printf 'lean-agent-contracts: lazy PASS case=%s policy=%s ready=%s target_exists=%s target_writable=%s\n' \
    "$label" "$policy" "$ready" "$target_exists" "$target_writable"
}

check_lazy_fixture() {
  read_fixture_allow "$fixture_root/config-fixture.yaml"
  read_fixture_env "$fixture_root/runtime-env.txt"
  local target_path=
  [[ -n $lazy_target ]] && target_path=$fixture_root/$lazy_target
  assert_lazy_policy "$target_path" true true durable-target

  local saved_allow=$lazy_allow saved_disable=$lazy_disable saved_target=$lazy_target
  lazy_allow=false
  assert_lazy_policy "$target_path" false false config-veto
  lazy_allow=true; lazy_disable=1; lazy_target=
  assert_lazy_policy '' false false sealed-without-target
  lazy_allow=$saved_allow; lazy_disable=$saved_disable; lazy_target=$saved_target
}

check_foreground_files() {
  local schema=$1 skill=$2 skills_list=$3
  require_literal "$schema" 'Foreground (default)' 'terminal schema'
  require_literal "$schema" 'notify_on_complete=true' 'terminal schema'
  require_literal "$skill" 'result gates the current decision' 'decision-gate skill'
  require_literal "$skill" 'Do not use background followed by `process(wait)` merely to simulate foreground execution.' 'decision-gate skill'
  require_literal "$skills_list" 'autonomous-ai-agents' 'enabled skill list'
  require_literal "$skills_list" 'enabled' 'enabled skill list'
  printf '%s\n' 'lean-agent-contracts: foreground PASS schema=upstream skill=mounted decision_gate=preserved'
}

check_live_noninterference_contract() {
  local test_file=$root/ops/tests/test_lean_agent_deployment_contracts.sh expected='skills_output=$(docker exec --env '
  expected+='PYTHONDONTWRITEBYTECODE=1 "$container" hermes skills list 2>&1)'
  require_literal "$test_file" "$expected" 'live skills list bytecode suppression'
  printf '%s\n' 'lean-agent-contracts: live non-interference PASS skills_list_bytecode=disabled'
}

check_webui_ownership() {
  local image=$root/ops/images/Dockerfile.moss-all-in-one
  local gateway=$root/ops/webui-overrides/api/gateway_chat.py
  local profiles=$root/ops/webui-overrides/api/profiles.py
  local supervisor=$root/ops/supervisor/moss-all-in-one-supervisord.conf
  local docs=$root/docs/VALIDATION.md
  require_literal "$image" 'ARG HERMES_WEBUI_REPO=https://github.com/rcortese/hermes-webui.git' 'webui ownership'
  require_literal "$gateway" 'def profile_proxy_entries(' 'webui proxy ownership'
  require_literal "$profiles" 'def _append_profile_proxy_entries(' 'webui selector ownership'
  require_literal "$supervisor" '[program:moss-dashboard]' 'embedded dashboard preservation'
  require_literal "$docs" 'Selector and proxy contracts belong to the separately maintained' 'webui runbook'
  require_literal "$docs" '`hermes-webui` source surface.' 'webui runbook'
  require_literal "$docs" 'This does not retire the embedded Hermes' 'dashboard runbook'
  require_literal "$docs" 'dashboard; the current all-in-one supervisor still runs it' 'dashboard runbook'
  printf '%s\n' 'lean-agent-contracts: webui PASS selector_proxy=hermes-webui embedded_dashboard=preserved'
}

check_live() {
  command -v docker >/dev/null 2>&1 || fail 'live Docker CLI unavailable'
  docker inspect "$container" >/dev/null || fail "live container unavailable: $container"

  lazy_allow=$(docker exec "$container" env PYTHONDONTWRITEBYTECODE=1 /opt/hermes/.venv/bin/python -B -c \
    'from hermes_cli.config import load_config; print(str(bool((load_config().get("security") or {}).get("allow_lazy_installs", True))).lower())')
  lazy_disable=$(docker exec "$container" sh -c 'printf %s "${HERMES_DISABLE_LAZY_INSTALLS:-}"')
  lazy_target=$(docker exec "$container" sh -c 'printf %s "${HERMES_LAZY_INSTALL_TARGET:-}"')
  [[ $lazy_allow == true || $lazy_allow == false ]] || fail 'live lazy config result invalid'

  local policy=false ready=false exists=false writable=false
  if [[ $lazy_allow == true && ( $lazy_disable != 1 || -n $lazy_target ) ]]; then policy=true; fi
  if [[ -n $lazy_target ]] && docker exec -u hermes "$container" test -d "$lazy_target"; then exists=true; fi
  if [[ -n $lazy_target ]] && docker exec -u hermes "$container" test -w "$lazy_target"; then writable=true; fi
  if [[ $policy == true && ( -z $lazy_target || ( $exists == true && $writable == true ) ) ]]; then ready=true; fi
  [[ $policy == true && $ready == true ]] || fail "live lazy policy=$policy ready=$ready target_exists=$exists target_writable=$writable"
  printf 'lean-agent-contracts: lazy PASS case=live policy=%s ready=%s target_exists=%s target_writable=%s\n' "$policy" "$ready" "$exists" "$writable"

  docker exec "$container" grep -Fq 'Foreground (default)' /opt/hermes/tools/terminal_tool.py || fail 'live terminal schema lacks foreground default'
  docker exec "$container" grep -Fq 'notify_on_complete=true' /opt/hermes/tools/terminal_tool.py || fail 'live terminal schema lacks background notification contract'
  docker exec "$container" grep -Fq 'result gates the current decision' "$skill_path" || fail 'live mounted skill lacks foreground decision gate'
  docker exec "$container" grep -Fq 'Do not use background followed by `process(wait)` merely to simulate foreground execution.' "$skill_path" || fail 'live mounted skill lacks background/wait prohibition'
  local skills_output
  skills_output=$(docker exec --env PYTHONDONTWRITEBYTECODE=1 "$container" hermes skills list 2>&1)
  grep -Eq 'autonomous-ai-agents.*enabled' <<<"$skills_output" || fail 'live autonomous-ai-agents skill is not enabled'
  printf '%s\n' 'lean-agent-contracts: foreground PASS schema=live-upstream skill=live-mounted decision_gate=preserved'
}

check_all() {
  check_dockerfiles
  check_webui_ownership
  check_live_noninterference_contract
  if [[ $mode == fixture ]]; then
    check_lazy_fixture
    check_foreground_files "$fixture_root/terminal-schema.txt" "$fixture_root/decision-gate-skill.md" "$fixture_root/skills-list.txt"
  else
    check_live
  fi
  printf 'lean-agent-contracts: PASS mode=%s docker_effects=none\n' "$mode"
}

run_mutant() {
  local id=$1 path=$2 from=$3 to=$4 expected=$5 mutant
  mutant=$mutant_root/$id
  mkdir -p "$mutant/ops/images" "$mutant/ops/webui-overrides/api" "$mutant/ops/supervisor" "$mutant/ops/tests/fixtures" "$mutant/docs"
  # Copy only the declared dependencies of check_all/run_mutant. Historical
  # candidates and unrelated source trees are deliberately outside this fixture.
  cp -- "$root/ops/images/Dockerfile.moss" "$mutant/ops/images/Dockerfile.moss"
  cp -- "$root/ops/images/Dockerfile.moss-all-in-one" "$mutant/ops/images/Dockerfile.moss-all-in-one"
  cp -- "$root/ops/images/Dockerfile.jen" "$mutant/ops/images/Dockerfile.jen"
  cp -- "$root/ops/images/Dockerfile.denholm" "$mutant/ops/images/Dockerfile.denholm"
  cp -- "$root/ops/images/Dockerfile.richmond" "$mutant/ops/images/Dockerfile.richmond"
  cp -- "$root/ops/images/Dockerfile.roy" "$mutant/ops/images/Dockerfile.roy"
  cp -- "$root/ops/images/Dockerfile.the-elders" "$mutant/ops/images/Dockerfile.the-elders"
  cp -- "$root/ops/webui-overrides/api/gateway_chat.py" "$mutant/ops/webui-overrides/api/gateway_chat.py"
  cp -- "$root/ops/webui-overrides/api/profiles.py" "$mutant/ops/webui-overrides/api/profiles.py"
  cp -- "$root/ops/supervisor/moss-all-in-one-supervisord.conf" "$mutant/ops/supervisor/moss-all-in-one-supervisord.conf"
  cp -a -- "$root/ops/tests/fixtures/lean-agent-contracts" "$mutant/ops/tests/fixtures/"
  cp -- "$root/docs/VALIDATION.md" "$mutant/docs/VALIDATION.md"
  cp -- "$root/compose.yaml" "$mutant/compose.yaml"
  cp -- "$root/ops/tests/test_lean_agent_deployment_contracts.sh" "$mutant/ops/tests/test_lean_agent_deployment_contracts.sh"
  TARGET="$mutant/$path" FROM="$from" TO="$to" perl -0pi -e '
    BEGIN { $target=$ENV{TARGET}; $from=$ENV{FROM}; $to=$ENV{TO}; }
    if (s/\Q$from\E/$to/ != 1) { die "mutant setup failed for $target\n" }
  ' "$mutant/$path"
  if "$0" --mode fixture --repo-root "$mutant" --fixture-root "$mutant/ops/tests/fixtures/lean-agent-contracts" >"$mutant.out" 2>"$mutant.err"; then
    fail "mutant $id was accepted"
  fi
  grep -Fq "$expected" "$mutant.err" || { cat "$mutant.err" >&2; fail "mutant $id failed for wrong reason"; }
  printf 'lean-agent-contracts: mutant RED id=%s\n' "$id"
}

if ((self_test)); then
  [[ $mode == fixture ]] || fail '--self-test requires fixture mode'
  check_all
  mutant_root=$(mktemp -d "${TMPDIR:-/tmp}/lean-agent-contract-mutants.XXXXXX")
  trap 'rm -rf "$mutant_root"' EXIT
  run_mutant identity ops/images/Dockerfile.moss 'groupmod -o -g 100 hermes' 'groupmod -g 100 hermes' 'identity Dockerfile.moss missing'
  run_mutant terminal ops/tests/fixtures/lean-agent-contracts/terminal-schema.txt 'Foreground (default)' 'Foreground' 'terminal schema missing'
  run_mutant skill ops/tests/fixtures/lean-agent-contracts/decision-gate-skill.md 'result gates the current decision' 'result informs a later decision' 'decision-gate skill missing'
  run_mutant webui ops/webui-overrides/api/gateway_chat.py 'def profile_proxy_entries(' 'def profile_entries(' 'webui proxy ownership missing'
  skills_bytecode_from='  skills_output=$(docker exec --env '
  skills_bytecode_from+='PYTHONDONTWRITEBYTECODE=1 "$container" hermes skills list 2>&1)'
  skills_bytecode_to='  skills_output=$(docker exec "$container" hermes skills list 2>&1)'
  run_mutant skills-bytecode ops/tests/test_lean_agent_deployment_contracts.sh "$skills_bytecode_from" "$skills_bytecode_to" 'live skills list bytecode suppression missing'
  printf '%s\n' 'lean-agent-contracts: SELF_TEST PASS mutants=5'
  exit 0
fi

check_all
