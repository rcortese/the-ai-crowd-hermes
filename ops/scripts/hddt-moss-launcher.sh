#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
readonly ROOT=/mnt/ssd/appdata/the-ai-crowd-hddt EXECUTOR=$ROOT/bin/hddt-moss.sh SELF=$ROOT/bin/hddt-moss-launcher.sh HANDSHAKE_SECONDS=30
fail(){ printf 'HDDT launcher: %s\n' "$1" >&2; exit "${2:-65}"; }
[[ $# == 2 && $1 == --operation-id && $2 =~ ^[a-z0-9][a-z0-9-]{7,63}$ ]] || fail 'usage: --operation-id ID' 64
opid=$2; op=$ROOT/operations/$opid; auth=$ROOT/authorizations/$opid.ready
[[ -d $op && ! -L $op && -f $op/request.json && -f $auth ]] || fail 'operation or authorization missing'
[[ $(realpath -e "$ROOT") == "$ROOT" && $(realpath -e "$EXECUTOR") == "$EXECUTOR" && $(realpath -e "$SELF") == "$SELF" ]] || fail 'non-canonical installed path'
[[ $(stat -c %u "$ROOT") == 0 && $(stat -c %a "$ROOT") == 700 ]] || fail 'unsafe root custody'
[[ $(stat -c %a "$op") == 700 && $(stat -c %a "$auth") == 600 ]] || fail 'unsafe operation custody'
request_sha=$(jq -er '.request_sha256|strings|select(test("^[0-9a-f]{64}$"))' "$op/request.json") || fail 'invalid request'
launcher_sha=$(sha256sum "$SELF"|cut -d' ' -f1); executor_sha=$(sha256sum "$EXECUTOR"|cut -d' ' -f1)
jq -e --arg l "$launcher_sha" --arg e "$executor_sha" '.launcher_sha256==$l and .executor_sha256==$e and .mode=="followable"' "$op/request.json" >/dev/null || fail 'launcher binding mismatch'
launch=$op/runner.launch.json; started=$op/runner.started.json; exitrec=$op/runner.exit.json; log=$op/runner.log
[[ ! -e $launch && ! -e $started ]] || fail 'runner already launched'
start_epoch=$(date +%s); argv=$(jq -nc --arg e "$EXECUTOR" --arg id "$opid" '[$e,"run","--operation-id",$id]')
jq -ncS --arg request "$request_sha" --arg launcher "$launcher_sha" --arg executor "$executor_sha" --arg log "$log" --argjson argv "$argv" --argjson epoch "$start_epoch" '{request_sha256:$request,launcher_sha256:$launcher,executor_sha256:$executor,argv:$argv,log_path:$log,launch_epoch:$epoch}' >"$launch.tmp"; chmod 600 "$launch.tmp"; ln "$launch.tmp" "$launch" || { rm -f "$launch.tmp"; fail 'launch receipt publication race'; }; rm -f "$launch.tmp"
env -i HOME=/root PATH=/usr/bin:/bin nohup setsid "$EXECUTOR" run --operation-id "$opid" </dev/null >>"$log" 2>&1 &
pid=$!; sid=$(ps -o sid= -p "$pid"|tr -d ' '); pgid=$(ps -o pgid= -p "$pid"|tr -d ' '); token=$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true)
jq -ncS --arg request "$request_sha" --arg launcher "$launcher_sha" --arg executor "$executor_sha" --argjson pid "$pid" --arg sid "$sid" --arg pgid "$pgid" --arg token "$token" '{request_sha256:$request,launcher_sha256:$launcher,executor_sha256:$executor,pid:$pid,sid:$sid,pgid:$pgid,start_token:$token}' >"$started.tmp"; chmod 600 "$started.tmp"; ln "$started.tmp" "$started" || { rm -f "$started.tmp"; fail 'started receipt publication race'; }; rm -f "$started.tmp"
for ((i=0;i<HANDSHAKE_SECONDS;i++)); do if [[ -f $started ]] && jq -e --arg r "$request_sha" --argjson p "$pid" '.request_sha256==$r and .pid==$p' "$started" >/dev/null; then wait "$pid" || true; exit 0; fi; kill -0 "$pid" 2>/dev/null || break; sleep 1; done
jq -ncS --arg request "$request_sha" --arg launcher "$launcher_sha" --arg executor "$executor_sha" --argjson pid "$pid" --arg sid "$sid" --arg pgid "$pgid" --arg token "$token" '{request_sha256:$request,launcher_sha256:$launcher,executor_sha256:$executor,pid:$pid,sid:$sid,pgid:$pgid,start_token:$token}' >"$exitrec"; chmod 600 "$exitrec"; fail 'runner handshake timeout' 75
