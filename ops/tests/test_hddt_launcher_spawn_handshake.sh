#!/usr/bin/env bash
# Exercise the real production launcher bytes in an isolated mount namespace.
set -Eeuo pipefail
umask 077
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
launcher_source=$root/ops/scripts/hddt-moss-launcher.sh
fixed=/mnt/ssd/appdata/the-ai-crowd-hddt
[[ $(id -u) == 0 ]] || { printf '%s\n' 'launcher-spawn-handshake: FAIL requires root mount namespace' >&2; exit 77; }
unshare -m --propagation private true 2>/dev/null || { printf '%s\n' 'launcher-spawn-handshake: FAIL mount namespace unavailable' >&2; exit 77; }

tmp=$(mktemp -d /tmp/hddt-launcher-spawn.XXXXXX)
cleanup(){ rm -rf -- "$tmp"; }
trap cleanup EXIT

make_root(){
  local case_dir=$1 mode=$2 opid=$3 request launcher_sha executor_sha
  mkdir -m 700 -p "$case_dir/root/bin" "$case_dir/root/state/operations/$opid" "$case_dir/root/state/authorizations"
  install -m 700 "$launcher_source" "$case_dir/root/bin/hddt-moss-launcher.sh"
  if [[ $mode == mutant ]]; then
    perl -0pi -e 's#env -i HOME=/root PATH=/usr/bin:/bin nohup#env -i HOME=/root PATH=/usr/bin:/bin umask 077 nohup#' "$case_dir/root/bin/hddt-moss-launcher.sh"
  fi
  cat >"$case_dir/root/bin/hddt-moss.sh" <<'RUNNER'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
ROOT=/mnt/ssd/appdata/the-ai-crowd-hddt
[[ $# == 3 && $1 == run && $2 == --operation-id ]] || exit 64
op=$ROOT/state/operations/$3
request=$(jq -er .request_sha256 "$op/request.json")
launcher=$(sha256sum "$ROOT/bin/hddt-moss-launcher.sh" | cut -d' ' -f1)
executor=$(sha256sum "$ROOT/bin/hddt-moss.sh" | cut -d' ' -f1)
token=$(awk '{print $22}' "/proc/$$/stat")
sid=$(ps -o sid= -p $$ | tr -d ' ')
pgid=$(ps -o pgid= -p $$ | tr -d ' ')
jq -ncS --arg request "$request" --arg launcher "$launcher" --arg executor "$executor" --argjson pid "$$" --arg token "$token" --arg sid "$sid" --arg pgid "$pgid" '{request_sha256:$request,launcher_sha256:$launcher,executor_sha256:$executor,pid:$pid,start_token:$token,sid:$sid,pgid:$pgid}' >"$op/runner.started.json.tmp"
chmod 600 "$op/runner.started.json.tmp"
ln "$op/runner.started.json.tmp" "$op/runner.started.json"
rm -f "$op/runner.started.json.tmp"
trap 'exit 0' TERM INT HUP
while :; do sleep 1; done
RUNNER
  chmod 700 "$case_dir/root/bin/hddt-moss.sh"
  request=$(printf '%s' "$mode-$opid" | sha256sum | cut -d' ' -f1)
  launcher_sha=$(sha256sum "$case_dir/root/bin/hddt-moss-launcher.sh" | cut -d' ' -f1)
  executor_sha=$(sha256sum "$case_dir/root/bin/hddt-moss.sh" | cut -d' ' -f1)
  jq -ncS --arg approval fixture --arg candidate sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb --arg rollback sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --arg op "$opid" --arg request "$request" --arg exec "$executor_sha" --arg launcher "$launcher_sha" '{approval_context:$approval,candidate_image_id:$candidate,candidate_render_sha256:"1111111111111111111111111111111111111111111111111111111111111111",canonical_remote:"ssh://fixture/repo",confirmation_deadline_epoch:0,created_epoch:1,builder_sha256:"2222222222222222222222222222222222222222222222222222222222222222",executor_sha256:$exec,input_aggregate_sha256:"3333333333333333333333333333333333333333333333333333333333333333",launcher_sha256:$launcher,mode:"followable",moss_base_image:"fixture/base@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",operation_id:$op,request_sha256:$request,rollback_image_id:$rollback,rollback_render_sha256:"4444444444444444444444444444444444444444444444444444444444444444",source_closure_sha256:"5555555555555555555555555555555555555555555555555555555555555555",source_revision:"6666666666666666666666666666666666666666",source_tree:"7777777777777777777777777777777777777777"}' >"$case_dir/root/state/operations/$opid/request.json"
  jq -ncS --arg request "$request" --arg exec "$executor_sha" --arg launcher "$launcher_sha" '{request_sha256:$request,executor_sha256:$exec,launcher_sha256:$launcher}' >"$case_dir/root/state/operations/$opid/candidate-provenance.json"
  jq -ncS --arg request "$request" --arg exec "$executor_sha" --arg launcher "$launcher_sha" '{request_sha256:$request,executor_sha256:$exec,launcher_sha256:$launcher,operations:["run"],consumed:false}' >"$case_dir/root/state/authorizations/$opid.ready"
  chmod 600 "$case_dir/root/state/operations/$opid/"*.json "$case_dir/root/state/authorizations/$opid.ready"
  chown -R 0:0 "$case_dir/root"
}

run_namespace(){
  local case_dir=$1 opid=$2
  FIXTURE_ROOT="$case_dir/root" OPID="$opid" FIXED="$fixed" unshare -m --propagation private bash -c '
    set -Eeuo pipefail
    mount --bind "$FIXTURE_ROOT" "$FIXED"
    exec "$FIXED/bin/hddt-moss-launcher.sh" --operation-id "$OPID"
  '
}

stop_runner(){
  local started=$1 pid token cmd
  pid=$(jq -er .pid "$started"); token=$(jq -er .start_token "$started")
  [[ -r /proc/$pid/stat && $(awk '{print $22}' "/proc/$pid/stat") == "$token" ]] || return 1
  cmd=$(tr '\0' ' ' <"/proc/$pid/cmdline")
  [[ $cmd == *'/mnt/ssd/appdata/the-ai-crowd-hddt/bin/hddt-moss.sh run --operation-id '* ]] || return 1
  kill -TERM "$pid"
  for _ in {1..100}; do [[ ! -r /proc/$pid/stat || $(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true) != "$token" ]] && return 0; sleep .05; done
  return 1
}

good=$tmp/good; good_op=hddt-spawn-good-0001
make_root "$good" good "$good_op"
run_namespace "$good" "$good_op"
good_started=$good/root/state/operations/$good_op/runner.started.json
[[ -f $good_started && -f $good/root/state/operations/$good_op/runner.launch.json ]]
jq -e '.pid>1 and (.start_token|test("^[0-9]+$")) and (.sid|test("^[0-9]+$")) and (.pgid|test("^[0-9]+$"))' "$good_started" >/dev/null
[[ ! -s $good/root/state/operations/$good_op/runner.log ]]
stop_runner "$good_started"

bad=$tmp/bad; bad_op=hddt-spawn-bad-0001
make_root "$bad" mutant "$bad_op"
set +e
run_namespace "$bad" "$bad_op" >"$bad/stdout" 2>"$bad/stderr"
bad_rc=$?
set -e
[[ $bad_rc == 75 ]]
[[ -f $bad/root/state/operations/$bad_op/runner.launch.json && ! -e $bad/root/state/operations/$bad_op/runner.started.json ]]
[[ $(<"$bad/root/state/operations/$bad_op/runner.log") == "env: 'umask': No such file or directory" ]]
grep -Fxq 'HDDT launcher: runner exited before handshake' "$bad/stderr"

printf '%s\n' 'hddt-launcher-spawn-handshake: PASS good=spawned-and-identity-bound mutant=pre-handshake-exit causal=true'
