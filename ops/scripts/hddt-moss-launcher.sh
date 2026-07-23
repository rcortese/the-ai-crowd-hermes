#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
readonly ROOT=/mnt/ssd/appdata/the-ai-crowd-hddt STATE=$ROOT/state EXECUTOR=$ROOT/bin/hddt-moss.sh SELF=$ROOT/bin/hddt-moss-launcher.sh HANDSHAKE_SECONDS=30
fail(){ printf 'HDDT launcher: %s\n' "$1" >&2; exit "${2:-65}"; }
[[ $# == 2 && $1 == --operation-id && $2 =~ ^[a-z0-9][a-z0-9-]{7,63}$ ]] || fail 'usage: --operation-id ID' 64
opid=$2; op=$STATE/operations/$opid; auth=$STATE/authorizations/$opid.ready; receipt=$op/candidate-provenance.json
[[ -d $op && ! -L $op && -f $op/request.json && -f $receipt && -f $auth ]] || fail 'operation or authorization missing'
[[ $(realpath -e "$ROOT") == "$ROOT" && $(realpath -e "$STATE") == "$STATE" && $(realpath -e "$EXECUTOR") == "$EXECUTOR" && $(realpath -e "$SELF") == "$SELF" ]] || fail 'non-canonical installed path'
for p in "$ROOT" "$STATE" "$op"; do [[ $(stat -c %u "$p") == 0 && $(stat -c %a "$p") == 700 ]] || fail 'unsafe custody'; done
[[ $(stat -c %u "$auth") == 0 && $(stat -c %a "$auth") == 600 ]] || fail 'unsafe authorization custody'
keys='["approval_context","candidate_image_id","candidate_render_sha256","canonical_remote","confirmation_deadline_epoch","created_epoch","builder_sha256","executor_sha256","input_aggregate_sha256","launcher_sha256","mode","moss_base_image","operation_id","request_sha256","rollback_image_id","rollback_render_sha256","source_closure_sha256","source_revision","source_tree"]'
jq -e --argjson k "$keys" 'type=="object" and ((keys|sort)==($k|sort)) and .mode=="followable"' "$op/request.json" >/dev/null || fail 'request schema/mode invalid'
request_sha=$(jq -er '.request_sha256|strings|select(test("^[0-9a-f]{64}$"))' "$op/request.json") || fail 'invalid request hash'
launcher_sha=$(sha256sum "$SELF"|cut -d' ' -f1); executor_sha=$(sha256sum "$EXECUTOR"|cut -d' ' -f1)
[[ $(jq -er .launcher_sha256 "$receipt") == "$launcher_sha" && $(jq -er .executor_sha256 "$receipt") == "$executor_sha" ]] || fail 'installed execution-byte binding mismatch'
jq -e --arg l "$launcher_sha" --arg e "$executor_sha" --arg req "$request_sha" '.launcher_sha256==$l and .executor_sha256==$e and .request_sha256==$req' "$op/request.json" >/dev/null || fail 'request execution binding mismatch'
jq -e --arg l "$launcher_sha" --arg e "$executor_sha" --arg req "$request_sha" '.consumed==false and .request_sha256==$req and .launcher_sha256==$l and .executor_sha256==$e and .operations==["run"]' "$auth" >/dev/null || fail 'authorization binding mismatch'
launch=$op/runner.launch.json; started=$op/runner.started.json; exitrec=$op/runner.exit.json; log=$op/runner.log
[[ ! -e $launch && ! -e $started ]] || fail 'runner already launched'
argv=$(jq -nc --arg e "$EXECUTOR" --arg id "$opid" '[$e,"run","--operation-id",$id]')
jq -ncS --arg request "$request_sha" --arg launcher "$launcher_sha" --arg executor "$executor_sha" --arg log "$log" --argjson argv "$argv" --argjson epoch "$(date +%s)" '{request_sha256:$request,launcher_sha256:$launcher,executor_sha256:$executor,argv:$argv,log_path:$log,launch_epoch:$epoch}' >"$launch.tmp"; chmod 600 "$launch.tmp"; ln "$launch.tmp" "$launch" || { rm -f "$launch.tmp"; fail 'launch receipt publication race'; }; rm -f "$launch.tmp"
env -i HOME=/root PATH=/usr/bin:/bin umask 077 nohup setsid "$EXECUTOR" run --operation-id "$opid" </dev/null >>"$log" 2>&1 &
pid=$!
start=$(date +%s); while (( $(date +%s)-start < HANDSHAKE_SECONDS )); do
 if [[ -f $started ]] && jq -e --arg r "$request_sha" --arg l "$launcher_sha" --arg e "$executor_sha" --argjson p "$pid" '.request_sha256==$r and .launcher_sha256==$l and .executor_sha256==$e and .pid==$p' "$started" >/dev/null; then
  token=$(jq -er .start_token "$started"); sid=$(jq -er .sid "$started"); pgid=$(jq -er .pgid "$started"); [[ -r /proc/$pid/stat && $(awk '{print $22}' /proc/$pid/stat)=="$token" && $(ps -o sid= -p "$pid"|tr -d ' ')=="$sid" && $(ps -o pgid= -p "$pid"|tr -d ' ')=="$pgid" ]] || fail 'runner identity mismatch' 75
  exit 0
 fi
 [[ -r /proc/$pid/stat ]] || fail 'runner exited before handshake' 75
 sleep 0.1
done
fail 'runner handshake timeout' 75
