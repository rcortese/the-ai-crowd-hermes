#!/usr/bin/env bash
set -euo pipefail

script=$(realpath "${1:?script path required}")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
bin="$tmp/bin"
stack="$tmp/stack"
mkdir -p "$bin" "$stack/ops/deploy-runs"
printf '%s\n' 'services:' '  moss:' '    image: fixture/moss:local' >"$stack/compose.yaml"
base=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
candidate=cccccccccccccccccccccccccccccccccccccccc
export FAKE_STATE="$tmp/state"
mkdir -p "$FAKE_STATE"
export FAKE_BASE="$base" FAKE_CANDIDATE="$candidate"

cat >"$bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'git %s\n' "$*" >>"$FAKE_STATE/calls"
if [[ $1 == -C ]]; then shift 2; fi
case "$1 $2" in
  'rev-parse HEAD')
    if [[ -e "$FAKE_STATE/checked-out" ]]; then printf '%s\n' "$FAKE_CANDIDATE"; else printf '%s\n' "$FAKE_BASE"; fi
    ;;
  'diff --quiet') exit 0 ;;
  'diff --cached') [[ ${3:-} == --quiet ]]; exit 0 ;;
  'diff --name-only') printf '%s\n' compose.yaml ;;
  'checkout --detach')
    if [[ $3 == "$FAKE_CANDIDATE" ]]; then
      touch "$FAKE_STATE/checked-out"
    elif [[ $3 == "$FAKE_BASE" ]]; then
      rm -f "$FAKE_STATE/checked-out"
    else
      exit 93
    fi
    ;;
  *) echo "unexpected git argv: $*" >&2; exit 91 ;;
esac
EOF

cat >"$bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker %s\n' "$*" >>"$FAKE_STATE/calls"
if [[ $1 == exec && $3 == curl ]]; then
  count=0
  [[ ! -f "$FAKE_STATE/health-count" ]] || count=$(<"$FAKE_STATE/health-count")
  count=$((count + 1)); printf '%s\n' "$count" >"$FAKE_STATE/health-count"
  response=$(sed -n "${count}p" "$FAKE_HEALTH_SEQUENCE")
  printf '%b\n' "$response"
  exit 0
fi
if [[ $1 == exec && $3 == sh ]]; then exit 0; fi
if [[ $1 == compose && " $* " == *' config -q '* ]]; then exit 0; fi
if [[ $1 == compose && " $* " == *' up -d '* ]]; then touch "$FAKE_STATE/compose-up"; exit 0; fi
if [[ $1 == inspect && ${3:-} == --format ]]; then
  if [[ -e "$FAKE_STATE/compose-up" ]]; then
    printf '%s\n' 'pre-id sha256:image 2026-01-01T00:00:00Z 0 healthy'
  else
    printf '%s\n' 'pre-id sha256:image 2026-01-01T00:00:00Z 0 healthy'
  fi
  exit 0
fi
if [[ $1 == inspect ]]; then
  if [[ -e "$FAKE_STATE/compose-up" ]]; then
    printf '%s\n' '[{"Id":"post-id","Image":"sha256:image","RestartCount":0,"State":{"StartedAt":"2026-01-01T00:01:00Z","Health":{"Status":"healthy"}}}]'
  else
    printf '%s\n' '[{"Id":"pre-id","Image":"sha256:image","RestartCount":0,"State":{"StartedAt":"2026-01-01T00:00:00Z","Health":{"Status":"healthy"}}}]'
  fi
  exit 0
fi
echo "unexpected docker argv: $*" >&2
exit 92
EOF

cat >"$bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'curl %s\n' "$*" >>"$FAKE_STATE/calls"
exit 0
EOF
cat >"$bin/sleep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'sleep %s\n' "$*" >>"$FAKE_STATE/calls"
EOF
chmod +x "$bin"/*

reset_case() {
  rm -rf "$FAKE_STATE"
  mkdir -p "$FAKE_STATE"
  rm -rf "$stack/ops/deploy-runs"
  mkdir -p "$stack/ops/deploy-runs"
}
run_executor() {
  PATH="$bin:$PATH" bash "$script" \
    --stack-dir "$stack" --base "$base" --candidate "$candidate" \
    --service moss --container the-ai-crowd-moss-1 --execute
}

reset_case
set +e
PATH="$bin:$PATH" bash "$script" --help >"$tmp/help.out" 2>"$tmp/help.err"
help_rc=$?
PATH="$bin:$PATH" bash "$script" \
  --stack-dir "$stack" --base "$base" --candidate "$candidate" \
  --service moss --container the-ai-crowd-moss-1 >"$tmp/no-exec.out" 2>"$tmp/no-exec.err"
no_exec_rc=$?
set -e
[[ $help_rc -eq 0 ]]
[[ $no_exec_rc -eq 64 ]]
[[ ! -e "$FAKE_STATE/calls" ]]
grep -q -- '--execute' "$tmp/help.out"

reset_case
cat >"$tmp/health-active" <<'EOF'
{"status":"ok","active_streams":1,"active_runs":1,"runs":[{"id":"run-1"}]}
EOF
export FAKE_HEALTH_SEQUENCE="$tmp/health-active"
set +e
run_executor >"$tmp/active.out" 2>&1
active_rc=$?
set -e
[[ $active_rc -ne 0 ]]
[[ ! -e "$FAKE_STATE/compose-up" ]]
grep -q 'active streams present' "$tmp/active.out"

reset_case
cat >"$tmp/health-trailing" <<'EOF'
{"status":"ok","active_streams":0,"active_runs":0,"runs":[]}\nnot-json
EOF
export FAKE_HEALTH_SEQUENCE="$tmp/health-trailing"
set +e
run_executor >"$tmp/trailing.out" 2>&1
trailing_rc=$?
set -e
[[ $trailing_rc -ne 0 ]]
[[ ! -e "$FAKE_STATE/compose-up" ]]
grep -q 'failed to read first WebUI drain snapshot' "$tmp/trailing.out"

reset_case
cat >"$tmp/health-final-active" <<'EOF'
{"status":"ok","active_streams":0,"active_runs":0,"runs":[]}
{"status":"ok","active_streams":0,"active_runs":0,"runs":[]}
{"status":"ok","active_streams":1,"active_runs":1,"runs":[{"id":"late-run"}]}
EOF
export FAKE_HEALTH_SEQUENCE="$tmp/health-final-active"
set +e
run_executor >"$tmp/final-active.out" 2>&1
final_active_rc=$?
set -e
[[ $final_active_rc -ne 0 ]]
[[ ! -e "$FAKE_STATE/compose-up" ]]
[[ ! -e "$FAKE_STATE/checked-out" ]]
grep -q 'active streams appeared immediately before lifecycle' "$tmp/final-active.out"
grep -q "git -C $stack checkout --detach $candidate" "$FAKE_STATE/calls"
grep -q "git -C $stack checkout --detach $base" "$FAKE_STATE/calls"

reset_case
cat >"$tmp/health-clear" <<'EOF'
{"status":"ok","active_streams":0,"active_runs":0,"runs":[]}
{"status":"ok","active_streams":0,"active_runs":0,"runs":[]}
{"status":"ok","active_streams":0,"active_runs":0,"runs":[]}
EOF
export FAKE_HEALTH_SEQUENCE="$tmp/health-clear"
run_executor >"$tmp/success.out" 2>&1
[[ -e "$FAKE_STATE/compose-up" ]]
[[ $(grep -c '^docker exec the-ai-crowd-moss-1 curl .*127.0.0.1:8787/health' "$FAKE_STATE/calls") -eq 3 ]]
[[ $(grep -c '^sleep 15$' "$FAKE_STATE/calls") -eq 1 ]]
terminal_json=$(find "$stack/ops/deploy-runs" -mindepth 2 -maxdepth 2 -name terminal.json -print -quit)
[[ -n "$terminal_json" ]]
executor_copy="${terminal_json%/terminal.json}/executor.sh"
[[ -f "$executor_copy" ]]
[[ "$(sha256sum "$executor_copy" | cut -d' ' -f1)" == "$(sha256sum "$script" | cut -d' ' -f1)" ]]
jq -e --arg base "$base" --arg candidate "$candidate" --arg executor_sha "$(sha256sum "$script" | cut -d' ' -f1)" '
  .base_commit == $base
  and .candidate_commit == $candidate
  and .scope == ["compose.yaml"]
  and .drain.stable_zero_observations == 3
  and .executor.sha256 == $executor_sha
  and .activation.service == "moss"
  and .result == "SUCCEEDED"
' "$terminal_json" >/dev/null

printf 'promote-moss-compose-candidate-tests: PASS (explicit execute, fail-closed drain, three observations, source binding)\n'
