#!/usr/bin/env bash
# Causal fake-first HDDT matrix. Every Txx runs in an isolated process/root.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.."&&pwd); SCRIPT=${HDDT_SCRIPT:-$ROOT/ops/scripts/hddt-moss.sh}; STATUS=${HDDT_STATUS_SCRIPT:-$ROOT/ops/scripts/hddt-moss-status.sh}; ADAPTER=${HDDT_ADAPTER_SCRIPT:-$ROOT/ops/scripts/validate-moss-native-conversation.sh}
CAND=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; ROLL=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; REV=1111111111111111111111111111111111111111; BASE_REV=3333333333333333333333333333333333333333; TREE=2222222222222222222222222222222222222222; REMOTE=ssh://fixture/repo; BASE=fixture/base@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd; CLOSURE=$(printf 'fixture closure\n'|sha256sum|cut -d' ' -f1); export CAND ROLL BASE BASE_REV REV
fail(){ printf 'ASSERT[%s]: %s\n' "${CASE:-?}" "$*" >&2; exit 1; }; eq(){ [[ $1 == "$2" ]]||fail "expected <$2>, got <$1>"; }; has(){ grep -Fq -- "$2" "$1"||fail "$1 lacks $2"; }; lacks(){ ! grep -Fq -- "$2" "$1"||fail "$1 contains $2"; }; state_is(){ eq "$(jq -r .state "$OP/terminal.json")" "$1"; }; last_is(){ eq "$(awk -F '\t' 'END{print $2}' "$OP/journal.log")" "$1"; }; zero_effects(){ [[ ! -s $FX/mutations.log ]]||fail 'unexpected lifecycle effect'; }; no_tmps(){ ! find "$STATE" -name '.tmp.*' -o -name '*.tmp'|grep -q .||fail 'temporary residue'; }
fixture(){
 FX=$(mktemp -d "/tmp/hddt-${CASE}.XXXXXX"); STATE=$FX/state; STACK=$FX/stack; BIN=$FX/bin; LIVE=$FX/live.json; CLOCK=$FX/clock; OP=$STATE/operations/hddt-case-0001; mkdir -m700 "$STATE" "$STACK" "$BIN"; mkdir -m700 "$STATE/build-receipts" "$STACK/env"; printf '100\n'>$CLOCK; printf 'services:\n  moss:\n    image: "${MOSS_IMAGE_REF}"\n'>$STACK/compose.yaml; printf 'FLEET=1\n'>$STACK/.env; printf 'A=1\n'>$STACK/env/fleet.env; printf 'B=1\n'>$STACK/env/moss-webui.env; chmod 600 "$STACK/.env" "$STACK/env/"*.env
 jq -nc --arg id preapply-container --arg image "$ROLL" '{Id:$id,Image:$image,Name:"/the-ai-crowd-moss-1",RestartCount:0,State:{Running:true,Status:"running",Health:{Status:"healthy"},StartedAt:"preapply-start"},Config:{Labels:{"com.docker.compose.project":"the-ai-crowd","com.docker.compose.service":"moss"}},NetworkSettings:{Networks:{fixture:{IPAddress:"172.20.0.8"}}},Mounts:[{Source:"/safe/runtime",Destination:"/opt/data"}]}' >$LIVE
 cat >$BIN/docker <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
fx=$(cd "$(dirname "$0")/.."&&pwd); live=$fx/live.json; printf '%s\t' "${HDDT_FAKE_PHASE:-call}" >>$fx/argv.log; printf '<%s>' "$@" >>$fx/argv.log; printf '\tENV=' >>$fx/argv.log; env|sort|tr '\n' ',' >>$fx/argv.log; printf '\n' >>$fx/argv.log
if [[ ${1:-} == inspect && ${2:-} == --format && ${3:-} == "{{json .Mounts}}" ]]; then jq '.Mounts' "$live"; exit; fi
if [[ ${1:-} == image && ${2:-} == inspect ]]; then image=${3:-}; [[ $image == "$BASE" && -e $fx/base.absent ]]&&exit 46; [[ $image == "$CAND" && -e $fx/candidate.absent ]]&&exit 46; [[ $image == "$ROLL" && -e $fx/rollback.absent ]]&&exit 46; jq -nc --arg id "$image" '{Id:$id}'; exit; fi
if [[ ${1:-} == inspect ]]; then
 if [[ -e $fx/live.block ]]; then : >$fx/live.entered; kill -TERM "$PPID"; fi
 c=$fx/inspect.count; n=$(( $(cat "$c" 2>/dev/null||echo 0)+1 )); echo $n>$c; if [[ -e $fx/after-apply && -e $fx/created-once ]]; then rm "$fx/created-once"; jq '.State.Running=false|.State.Status="created"|.State.Health.Status="none"' "$live"; exit; fi; for drift in id start restart; do if [[ -e $fx/after-apply && -e $fx/candidate-$drift-drift ]]; then seen=$fx/candidate-$drift-seen; if [[ -e $seen ]]; then case $drift in id) jq '.Id="candidate-id-drift"' "$live";; start) jq '.State.StartedAt="candidate-start-drift"' "$live";; restart) jq '.RestartCount=1' "$live";; esac; else touch "$seen"; cat "$live"; fi; exit; fi; done; if [[ -e $fx/after-apply && -e $fx/restart-drift ]]; then seen=$fx/restart-seen; if [[ -e $seen ]]; then jq '.RestartCount=1' "$live"; else touch "$seen"; jq '.RestartCount=0' "$live"; fi; exit; fi; [[ -f $fx/inspect.$n.json ]]&&cat $fx/inspect.$n.json||cat "$live"; exit; fi
if [[ ${1:-} == compose ]]; then
 for ((i=1;i<=$#;i++)); do a=${!i}; if [[ $a == -f || $a == --env-file ]]; then j=$((i+1)); printf '%s\n' "${!j}" >>$fx/opens.log; fi; done
 if [[ " $* " == *' config --format json '* ]]; then [[ -e $fx/render.fail ]]&&exit 42; grep -q '^extra:' "$fx/stack/compose.yaml" && exit 42; jq -nc --arg image "${MOSS_IMAGE_REF:?}" '{services:{moss:{image:$image}}}'; exit; fi
 if [[ " $* " == *' up -d '* ]]; then printf '%s\n' compose-up >>$fx/mutations.log; touch $fx/after-apply; f=; while (($#)); do [[ $1 == -f ]]&&{ f=$2; break; }; shift; done; if [[ $f == "$fx/stack/compose.yaml" ]]; then image=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; else image=$(jq -r .services.moss.image "$f"); fi; [[ -e $fx/apply.fail && $image == sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ]]&&exit 43; [[ -e $fx/rollback.fail && $image == sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ]]&&exit 44; [[ -e $fx/apply.wrong && $image == sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ]]&&image=sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee; [[ -e $fx/rollback.wrong && $image == sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ]]&&image=sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee; id=$(jq -r .Id "$live"); started=$(jq -r .State.StartedAt "$live"); jq --arg image "$image" --arg id "$id" --arg started "$started" '.Image=$image|.Id=$id|.State.Running=true|.State.Status="running"|.State.Health.Status="healthy"|.State.StartedAt=$started' "$live">$live.tmp; mv $live.tmp "$live";
 if [[ $image == sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb && -e $fx/apply.block ]]; then : >$fx/apply.entered; kill -INT "$PPID"; fi
 exit; fi
fi
if [[ ${1:-} == exec ]]; then
 cid=${2:-}; url=${!#}; case "$url" in http://127.0.0.1:8787/health) p=health-8787;; http://127.0.0.1:8644/health) p=health-8644;; http://127.0.0.1:8648/health) p=health-8648;; *) exit 92;; esac
 [[ ${3:-} == /usr/bin/curl && ${4:-} == --fail && ${5:-} == --silent && ${6:-} == --show-error && ${7:-} == --max-time && ${8:-} == 5 ]] || exit 92
 printf 'container\t%s\t%s\tcontainer\n' "$cid" "$url" >>$fx/probes.log
 [[ $(jq -r .Image "$live") == "$CAND" && -e $fx/probe.$p.fail ]]&&exit 45; c=$fx/probe.$p.count; n=$(( $(cat "$c" 2>/dev/null||echo 0)+1 )); echo $n>$c
 if [[ $(jq -r .Image "$live") == "$CAND" && -f $fx/probe.$p.fail-until ]]; then limit=$(cat "$fx/probe.$p.fail-until"); (( n <= limit ))&&exit 45; fi
 [[ $(jq -r .Image "$live") == "$ROLL" && -e $fx/rollback.probe.fail ]]&&exit 45
 exit 0
fi
exit 90
EOF
 cat >$BIN/curl <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
fx=$(cd "$(dirname "$0")/.."&&pwd); url=${!#}
[[ ${1:-} == --fail && ${2:-} == --silent && ${3:-} == --show-error && ${4:-} == --max-time && ${5:-} == 5 && $url == http://127.0.0.1:8644/health ]] || exit 92
printf 'host\t-\t%s\thost\n' "$url" >>$fx/probes.log
[[ $(jq -r .Image "$fx/live.json") == "$CAND" && -e $fx/probe.host-health-8644.fail ]]&&exit 45
exit 0
EOF
 cat >$BIN/git <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
fx=${FAKE_ROOT:?}; printf '<%s>' "$@" >>$fx/git.log; printf '\n' >>$fx/git.log
case " $* " in *"rev-parse HEAD^{tree}"*) cat $fx/git.tree;; *"rev-parse --verify ${BASE_REV}^{commit}"*) [[ ! -e $fx/git.base.absent ]] || exit 46; printf '%s\n' "$BASE_REV";; *"rev-parse --verify ${REV}^{commit}"*) printf '%s\n' "$REV";; *' rev-parse HEAD'*) cat $fx/git.head;; *"merge-base --is-ancestor $BASE_REV $REV"*) [[ ! -e $fx/git.base.nonancestor ]] || exit 1;; *'remote get-url origin'*) cat $fx/git.remote;; *' diff --quiet'*) [[ ! -e $fx/git.dirty ]];; *' ls-tree -r --full-tree HEAD '*) printf 'fixture closure\n';; *) exit 91;; esac
EOF
 cat >$BIN/native <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '<%s>' "$@" >>"$FAKE_ROOT/native.log"; printf '\n' >>"$FAKE_ROOT/native.log"; [[ ! -e $FAKE_ROOT/native.fail && ! -e $FAKE_ROOT/native.cleanup-fail ]]
EOF
 cat >$BIN/sleep <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${HDDT_REAL_SIGNAL_SLEEP:-0} == 1 ]]; then : >"$FAKE_ROOT/probe.sleep.entered"; kill -TERM "$PPID"; exit 0; fi
if [[ -e "$FAKE_ROOT/signal.await" ]]; then kill -INT "$PPID"; fi
n=$(cat "$HDDT_CLOCK_FILE"); printf '%s\n' "$((n+1))" >"$HDDT_CLOCK_FILE"
EOF
 chmod +x $BIN/*; printf '%s\n' "$REV">$FX/git.head; printf '%s\n' "$TREE">$FX/git.tree; printf '%s\n' "$REMOTE">$FX/git.remote; printf '%s\n' "$CLOSURE">$FX/git.closure; :>$FX/mutations.log; :>$FX/opens.log; :>$FX/argv.log; :>$FX/probes.log
 export HDDT_REHEARSAL=1 HDDT_STATE_ROOT=$STATE HDDT_STACK_ROOT=$STACK HDDT_DOCKER_BIN=$BIN/docker HDDT_CURL_BIN=$BIN/curl HDDT_GIT_BIN=$BIN/git HDDT_NATIVE_ADAPTER=$BIN/native HDDT_CUSTODY_UID=$(id -u) HDDT_CLOCK_FILE=$CLOCK HDDT_SLEEP_BIN=$BIN/sleep HDDT_SLEEP_SECONDS=0 HDDT_PROBE_SECONDS=4 HDDT_CONFIRMATION_SECONDS=20 FAKE_ROOT=$FX HDDT_CANDIDATE_IMAGE_ID=$CAND HDDT_EXPECTED_NETWORK=fixture
 chmod 700 "$STATE" "$STACK"; receipt
}
receipt(){ local f=$STATE/build-receipts/sha256-${CAND#sha256:}.json exec; exec=$(sha256sum "$SCRIPT"|cut -d' ' -f1); jq -ncS --arg rev "$REV" --arg source_base "$BASE_REV" --arg tree "$TREE" --arg remote "$REMOTE" --arg image "$CAND" --arg base "$BASE" --arg closure "$CLOSURE" --arg exec "$exec" '{source_revision:$rev,source_base_revision:$source_base,source_tree:$tree,source_remote:$remote,source_closure_sha256:$closure,candidate_image_id:$image,base_image:$base,context_sha256:"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",executor_sha256:$exec,toolchain_sha256:"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",created_epoch:1}' >$f; chmod 600 $f; RECEIPT_SHA=$(sha256sum $f|cut -d' ' -f1); }
prepare(){ "$SCRIPT" prepare --operation-id hddt-case-0001 --mode "${1:-automatic}" --source-revision "$REV" --source-tree "$TREE" --canonical-remote "$REMOTE" --candidate-image-id "$CAND" --rollback-image-id "$ROLL" --moss-base-image "$BASE" --receipt-sha256 "$RECEIPT_SHA" --approval-context reviewed-fixture; }
auth(){ load_req; jq -ncS --arg op hddt-case-0001 --arg req "$request_sha256" --arg candidate "$CAND" --arg rollback "$ROLL" --arg base "$BASE" --arg rev "$REV" --arg tree "$TREE" --arg remote "$REMOTE" --arg cand "$candidate_render_sha256" --arg roll "$rollback_render_sha256" --arg exec "$executor_sha256" '{operation_id:$op,request_sha256:$req,candidate_image_id:$candidate,rollback_image_id:$rollback,moss_base_image:$base,source_revision:$rev,source_tree:$tree,source_remote:$remote,candidate_render_sha256:$cand,rollback_render_sha256:$roll,executor_sha256:$exec,operations:["run"],consumed:false,approval_id:"approval-0001",approval_channel:"fixture",approved_epoch:1,expires_epoch:999999}' >$STATE/authorizations/hddt-case-0001.ready; chmod 600 $STATE/authorizations/hddt-case-0001.ready; }
load_req(){ request_sha256=$(jq -er '.request_sha256|strings|select(test("^[0-9a-f]{64}$"))' "$OP/request.json"); candidate_render_sha256=$(jq -er '.candidate_render_sha256|strings|select(test("^[0-9a-f]{64}$"))' "$OP/request.json"); rollback_render_sha256=$(jq -er '.rollback_render_sha256|strings|select(test("^[0-9a-f]{64}$"))' "$OP/request.json"); executor_sha256=$(jq -er '.executor_sha256|strings|select(test("^[0-9a-f]{64}$"))' "$OP/request.json"); }
run(){ "$SCRIPT" run --operation-id hddt-case-0001; }
set_live(){ local image=$1 running=${2:-true} status=${3:-running} health=${4:-healthy} restarts=${5:-0}; jq --arg image "$image" --argjson running "$running" --arg status "$status" --arg health "$health" --argjson restarts "$restarts" '.Image=$image|.State.Running=$running|.State.Status=$status|.State.Health.Status=$health|.RestartCount=$restarts' "$LIVE">$LIVE.tmp; mv $LIVE.tmp "$LIVE"; }
preapply_snapshot(){ jq --arg request "$(jq -r .request_sha256 "$OP/request.json")" '{request_sha256:$request,container_id:.Id,image_id:.Image,running:.State.Running,status:.State.Status,health:(.State.Health.Status//"unavailable"),started_at:.State.StartedAt,restart_count:.RestartCount}' "$LIVE" >"$OP/snapshot.json"; chmod 600 "$OP/snapshot.json"; }
candidate_identity(){ local snapshot body hash; snapshot=$(sha256sum "$OP/snapshot.json"|cut -d' ' -f1); body=$(jq -ncS --arg request "$(jq -r .request_sha256 "$OP/request.json")" --arg snapshot "$snapshot" --argjson live "$(cat "$LIVE")" '{request_sha256:$request,snapshot_sha256:$snapshot,container_id:$live.Id,image_id:$live.Image,started_at:$live.State.StartedAt,restart_count:$live.RestartCount,expected_running:$live.State.Running,expected_status:$live.State.Status,expected_health:($live.State.Health.Status//"unavailable")}'); hash=$(printf '%s\n' "$body"|sha256sum|cut -d' ' -f1); jq -cS --arg hash "$hash" '.+{identity_sha256:$hash}' <<<"$body" >"$OP/candidate-identity.json"; chmod 600 "$OP/candidate-identity.json"; }
wait_state(){ local wanted=$1; for _ in {1..200}; do [[ -f $OP/journal.log ]]&&[[ $(awk -F '\t' 'END{print $2}' $OP/journal.log) == "$wanted" ]]&&return; sleep .01; done; fail "did not reach $wanted"; }
wait_file(){ local f=$1; for _ in {1..500}; do [[ -e $f ]]&&return; /usr/bin/sleep .01; done; fail "did not reach file $f"; }
lock_free(){ local f=$1; exec 9>"$f"; flock -n 9||fail "lock held $f"; flock -u 9; exec 9>&-; }
assert_signal_terminal(){ local expected=$1; state_is "$expected"; eq "$(find "$OP" -maxdepth 1 -name terminal.json|wc -l|tr -d ' ')" 1; eq "$(find "$STATE/outbox" -maxdepth 1 -name '*.ready'|wc -l|tr -d ' ')" 1; no_tmps; lock_free "$STATE/deploy.lock"; lock_free "$OP/control.lock"; }
# Each function injects and asserts the named contract; shared setup is not evidence.
t01(){ "$SCRIPT" --help >/dev/null; rc=0; "$SCRIPT" bogus >/dev/null 2>&1||rc=$?; eq "$rc" 64; zero_effects; }
t02(){ rc=0; "$SCRIPT" prepare --operation-id ../escape >/dev/null 2>&1||rc=$?; eq "$rc" 64; [[ ! -e $FX/escape ]]||fail traversal; zero_effects; }
t03(){ h1=$(prepare); h2=$(prepare); eq "$h1" "$h2"; no_tmps; before=$(sha256sum $OP/request.json); rc=0; "$SCRIPT" prepare --operation-id hddt-case-0001 --mode automatic --source-revision "$REV" --source-tree "$TREE" --canonical-remote wrong --candidate-image-id "$CAND" --rollback-image-id "$ROLL" --moss-base-image "$BASE" --receipt-sha256 "$RECEIPT_SHA" --approval-context reviewed-fixture >/dev/null 2>&1||rc=$?; eq "$rc" 65; eq "$before" "$(sha256sum $OP/request.json)"; }
t04(){ rc=0; "$SCRIPT" prepare --operation-id hddt-case-0001 --mode automatic --source-revision "$REV" --source-tree "$TREE" --canonical-remote "$REMOTE" --candidate-image-id "$ROLL" --rollback-image-id "$ROLL" --moss-base-image "$BASE" --receipt-sha256 "$RECEIPT_SHA" --approval-context reviewed-fixture >/dev/null 2>&1||rc=$?; eq "$rc" 64; zero_effects; }
t05(){ echo 9999999999999999999999999999999999999999>$FX/git.head; rc=0; prepare >/dev/null 2>&1||rc=$?; eq "$rc" 65; zero_effects; has $FX/git.log 'safe.directory='; }
t06(){
  touch "$FX/base.absent"; rc=0; prepare >/dev/null 2>&1||rc=$?; eq "$rc" 65; zero_effects; has "$FX/argv.log" '<image><inspect>'
  rm -f "$FX/base.absent"
  jq '.base_image="fixture/base@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"' "$STATE/build-receipts/sha256-${CAND#sha256:}.json" >"$FX/receipt.bad"; mv "$FX/receipt.bad" "$STATE/build-receipts/sha256-${CAND#sha256:}.json"; chmod 600 "$STATE/build-receipts/sha256-${CAND#sha256:}.json"; RECEIPT_SHA=$(sha256sum "$STATE/build-receipts/sha256-${CAND#sha256:}.json"|cut -d' ' -f1)
  rc=0; prepare >/dev/null 2>&1||rc=$?; [[ $rc == 65 ]] || fail receipt-base-binding-accepted; zero_effects
}
t07(){ touch $FX/candidate.absent; rc=0; prepare >/dev/null 2>&1||rc=$?; eq "$rc" 65; zero_effects; has $FX/argv.log '<image><inspect>'; }
t08(){ prepare; auth; set_live "$ROLL" true running none; rc=0; run >/dev/null 2>&1||rc=$?; [[ $rc == 65 ]] || fail health-none-admitted; state_is REJECTED_PRE_APPLY; zero_effects; }
t09(){ exec 9>$STATE/prepare.lock; flock -x 9; rc=0; prepare >/dev/null 2>&1||rc=$?; eq "$rc" 75; zero_effects; [[ ! -d $OP ]]||fail false-receipt; }
t10(){ export COMPOSE_FILE=hostile MOSS_IMAGE_REF=hostile; prepare >/dev/null; config_lines=$(grep '<config><--format><json>' $FX/argv.log); [[ $config_lines != *hostile* ]]||fail inherited-compose-env; grep -Eq '/staging/hddt-case-0001\.[^/]+/compose-inputs/compose.yaml$' $FX/opens.log||fail sealed-compose-open; eq "$(jq -r .services.moss.image $OP/candidate.rendered.json)" "$CAND"; eq "$(jq -r .services.moss.image $OP/rollback.rendered.json)" "$ROLL"; }
t11(){ hook=$BIN/fail-seal; printf '#!/usr/bin/env bash\nexit 73\n' >$hook; chmod +x $hook; export HDDT_BEFORE_SEAL_HOOK=$hook; rc=0; prepare >/dev/null 2>&1||rc=$?; unset HDDT_BEFORE_SEAL_HOOK; [[ $rc != 0 ]]||fail snapshot-write; zero_effects; [[ ! -d $OP ]]||fail partial-promotion; no_tmps; }
t12(){ prepare; auth; :>$FX/argv.log; :>$FX/opens.log; COMPOSE_FILE=hostile MOSS_IMAGE_REF=hostile run; state_is SUCCEEDED; has $FX/argv.log '<up><-d><--no-build><--no-deps><--force-recreate><moss>'; has $FX/opens.log "$OP/candidate.rendered.json"; lacks $FX/opens.log "$STACK/compose.yaml"; line=$(grep '<up>' $FX/argv.log); [[ $line == *'HOME=/root'* && $line != *'MOSS_'* && $line != *'COMPOSE_'* ]]||fail apply-env; }
t13(){ prepare; auth; printf '3\n' >"$FX/probe.health-8787.fail-until"; rc=0; run >/dev/null 2>&1||rc=$?; eq "$rc" 0; state_is SUCCEEDED; eq "$(grep -c $'VERIFYING_BASE\tretry_health-8787' $OP/journal.log)" 3; eq "$(grep -c compose-up $FX/mutations.log)" 1; has $FX/argv.log '<exec><preapply-container></usr/bin/curl><--fail><--silent><--show-error><--max-time><5><http://127.0.0.1:8787/health>'; has $FX/probes.log $'container\tpreapply-container\thttp://127.0.0.1:8787/health\tcontainer'; has $FX/probes.log $'container\tpreapply-container\thttp://127.0.0.1:8644/health\tcontainer'; has $FX/probes.log $'container\tpreapply-container\thttp://127.0.0.1:8648/health\tcontainer'; has $FX/probes.log $'host\t-\thttp://127.0.0.1:8644/health\thost'; }
t14(){ prepare; auth; touch $FX/created-once; run; state_is SUCCEEDED; has $OP/journal.log retry_created; eq "$(grep -c compose-up $FX/mutations.log)" 1; }
t15(){ prepare; auth; touch $FX/apply.wrong; rc=0; run >/dev/null 2>&1||rc=$?; [[ $rc != 0 ]]||fail expected-rollback; state_is RECOVERY_UNRESOLVED; has $OP/journal.log third_state; eq "$(grep -c compose-up $FX/mutations.log)" 1; [[ ! -s $FX/probes.log ]]||fail unexpected-third-state-probe; }
t16(){ prepare; auth; printf '99\n' >"$FX/probe.health-8787.fail-until"; rc=0; run >/dev/null 2>&1||rc=$?; [[ $rc != 0 ]]; state_is ROLLED_BACK; has $OP/journal.log probe_deadline; [[ $(cat $CLOCK) -ge 104 ]]||fail no-deadline; }
t17(){ prepare; auth; touch $FX/apply.wrong; rc=0; run >/dev/null 2>&1||rc=$?; state_is RECOVERY_UNRESOLVED; has $OP/journal.log third_state; eq "$(grep -c compose-up $FX/mutations.log)" 1; [[ ! -s $FX/probes.log ]]||fail unexpected-third-state-probe; }
t18(){ prepare; auth; touch $FX/restart-drift; rc=0; run >/dev/null 2>&1||rc=$?; [[ $rc != 0 ]]; state_is RECOVERY_UNRESOLVED; has $OP/journal.log third_state; eq "$(grep -c compose-up $FX/mutations.log)" 1; }
t19(){ prepare; auth; touch $FX/probe.health-8648.fail; rc=0; run >/dev/null 2>&1||rc=$?; [[ $rc != 0 ]]; state_is ROLLED_BACK; has $OP/journal.log probe_health-8648; lacks $OP/journal.log secret; }
t20(){ prepare; auth; run </dev/null >/dev/null; state_is SUCCEEDED; lacks $OP/journal.log pid; }
t21(){ prepare automatic; auth; run; state_is SUCCEEDED; has $OP/journal.log VERIFYING_AUTOMATIC; has $FX/native.log '<--container><the-ai-crowd-moss-1>'; }
t22(){ prepare automatic; auth; touch $FX/native.fail; rc=0; run >/dev/null 2>&1||rc=$?; [[ $rc != 0 ]]; state_is ROLLED_BACK; has $OP/journal.log native_failed; }
t23(){ prepare automatic; auth; touch $FX/native.cleanup-fail; rc=0; run >/dev/null 2>&1||rc=$?; [[ $rc != 0 ]]; state_is ROLLED_BACK; has $OP/journal.log native_failed; }
t24(){ prepare followable; auth; run >/dev/null 2>&1 & pid=$!; wait_state AWAITING_CONFIRMATION; "$SCRIPT" confirm --operation-id hddt-case-0001 --reason reviewed; wait $pid; state_is SUCCEEDED; has $OP/journal.log CONFIRMING; [[ -f $OP/control/decision.consumed ]]; }
t25(){ prepare followable; auth; run >/dev/null 2>&1 & pid=$!; wait_state AWAITING_CONFIRMATION; "$SCRIPT" rollback --operation-id hddt-case-0001 --reason operator; wait $pid||true; state_is ROLLED_BACK; has $OP/journal.log requested; }
t26(){ prepare followable; auth; rc=0; run >/dev/null 2>&1||rc=$?; [[ $rc != 0 ]]; state_is ROLLED_BACK; has $OP/journal.log confirmation_timeout; eq "$(grep -c $'ROLLING_BACK\tconfirmation_timeout' $OP/journal.log)" 1; }
t27(){ prepare followable; rc=0; "$SCRIPT" confirm --operation-id hddt-case-0001 >/dev/null 2>&1||rc=$?; eq "$rc" 65; zero_effects; auth; run >/dev/null 2>&1 & pid=$!; wait_state AWAITING_CONFIRMATION; "$SCRIPT" confirm --operation-id hddt-case-0001; wait $pid; rc=0; "$SCRIPT" confirm --operation-id hddt-case-0001 >/dev/null 2>&1||rc=$?; eq "$rc" 65; state_is SUCCEEDED; }
t28(){ prepare followable; auth; run >/dev/null 2>&1 & pid=$!; wait_state AWAITING_CONFIRMATION; touch $FX/probe.health-8787.fail; "$SCRIPT" confirm --operation-id hddt-case-0001; wait $pid||true; state_is ROLLED_BACK; has $OP/journal.log confirm_readback_failed; }
t29(){ prepare; auth; touch $FX/probe.host-health-8644.fail; run >/dev/null 2>&1||true; state_is ROLLED_BACK; has $OP/journal.log probe_host-health-8644; has $OP/journal.log ROLLED_BACK; has $FX/probes.log $'host\t-\thttp://127.0.0.1:8644/health\thost'; }
t30(){ prepare; auth; touch $FX/probe.health-8644.fail $FX/rollback.fail; run >/dev/null 2>&1||true; state_is ROLLBACK_FAILED; eq "$(grep -c compose-up $FX/mutations.log)" 2; lacks $FX/argv.log '<tag>'; }
t31(){ prepare; auth; touch $FX/probe.health-8644.fail $FX/rollback.wrong; run >/dev/null 2>&1||true; state_is ROLLBACK_FAILED; eq "$(jq -r .Image $LIVE)" sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee; }
t32(){ prepare; regular_private_test(){ [[ -f $1 && $(stat -c %a $1) == 600 ]]; }; regular_private_test $OP/request.json||fail mode; no_tmps; jq -e . $OP/request.json >/dev/null; }
t33(){ prepare; auth; run; [[ -s $OP/terminal.json && -s $STATE/outbox/hddt-case-0001.ready ]]; terminal_sha=$(sha256sum $OP/terminal.json|cut -d' ' -f1); eq "$(jq -r .terminal_sha256 $STATE/outbox/hddt-case-0001.ready)" "$terminal_sha"; }
t34(){ prepare; auth; hook=$BIN/kill-after-intent; printf '#!/usr/bin/env bash\nkill -KILL "$PPID"\n' >$hook; chmod +x $hook; export HDDT_AFTER_APPLY_INTENT_HOOK=$hook; rc=0; run >/dev/null 2>&1||rc=$?; unset HDDT_AFTER_APPLY_INTENT_HOOK; eq "$rc" 137; "$SCRIPT" recover --operation-id hddt-case-0001; state_is REJECTED_PRE_APPLY; eq "$(grep -c compose-up $FX/mutations.log)" 0; }
t35(){ prepare; preapply_snapshot; auth; set_live $CAND; candidate_identity; printf '101\tAPPLY_INTENT\tauthorization_consumed\n' >>$OP/journal.log; mv $STATE/authorizations/hddt-case-0001.ready $STATE/authorizations/hddt-case-0001.consumed; "$SCRIPT" recover --operation-id hddt-case-0001; state_is SUCCEEDED; zero_effects; }
t36(){ prepare; preapply_snapshot; set_live $CAND; candidate_identity; printf '101\tAPPLYING\tcandidate\n' >>$OP/journal.log; "$SCRIPT" recover --operation-id hddt-case-0001; state_is SUCCEEDED; has $OP/journal.log recovered_candidate; }
t37(){ prepare; preapply_snapshot; printf '101\tAPPLYING\tcandidate\n' >>$OP/journal.log; "$SCRIPT" recover --operation-id hddt-case-0001; state_is ROLLED_BACK; zero_effects; }
t38(){ prepare; preapply_snapshot; set_live sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee; printf '101\tAPPLYING\tcandidate\n' >>$OP/journal.log; "$SCRIPT" recover --operation-id hddt-case-0001; state_is RECOVERY_UNRESOLVED; zero_effects; has $OP/journal.log third_state; }
t39(){ prepare; preapply_snapshot; rm $OP/snapshot.json; set_live $CAND; printf '101\tAPPLYING\tcandidate\n' >>$OP/journal.log; rc=0; "$SCRIPT" recover --operation-id hddt-case-0001 >/dev/null 2>&1||rc=$?; eq "$rc" 2; state_is RECOVERY_UNRESOLVED; zero_effects; has $OP/journal.log snapshot_invalid; }
t40(){ prepare; auth; run; set_live $ROLL; before=$(sha256sum $LIVE); out=$("$STATUS" --operation-id hddt-case-0001); jq -e '.divergence==true and .live.image_id=="'$ROLL'"' <<<"$out" >/dev/null; eq "$before" "$(sha256sum $LIVE)"; }
t41(){ rm -rf $STATE; ln -s $STACK $STATE; export HDDT_STATE_ROOT=$STATE; rc=0; prepare >/dev/null 2>&1||rc=$?; [[ $rc != 0 ]]; zero_effects; [[ ! -e $STACK/operations ]]||fail target-state-write; }
t42(){ f=$STATE/build-receipts/sha256-${CAND#sha256:}.json; outside=$FX/outside; cp $f $outside; rm $f; ln -s $outside $f; rc=0; prepare >/dev/null 2>&1||rc=$?; eq "$rc" 65; zero_effects; eq "$(sha256sum $outside)" "$(sha256sum $outside)"; }
t43(){ prepare followable; auth; run >/dev/null 2>&1 & pid=$!; wait_state AWAITING_CONFIRMATION; ( "$SCRIPT" confirm --operation-id hddt-case-0001 --reason first >/dev/null 2>&1 ) & a=$!; ( "$SCRIPT" rollback --operation-id hddt-case-0001 --reason second >/dev/null 2>&1 ) & b=$!; wait $a||true; wait $b||true; wait $pid||true; [[ -f $OP/terminal.json ]]; eq "$(find $OP/control -name 'decision.*'|wc -l)" 1; eq "$(grep -Ec $'\t(SUCCEEDED|ROLLED_BACK)\t' $OP/journal.log)" 1; }
t44(){ prepare; auth; jq '.operations=["run","any"]' $STATE/authorizations/hddt-case-0001.ready>$FX/a; mv $FX/a $STATE/authorizations/hddt-case-0001.ready; chmod 600 $STATE/authorizations/hddt-case-0001.ready; run >/dev/null 2>&1||true; state_is REJECTED_PRE_APPLY; zero_effects; [[ -f $STATE/authorizations/hddt-case-0001.ready ]]; }
t45(){ prepare; eq "$(jq -r .services.moss.image $OP/candidate.rendered.json)" "$CAND"; eq "$(jq -r .services.moss.image $OP/rollback.rendered.json)" "$ROLL"; printf 'extra: true\n' >>$STACK/compose.yaml; printf '%064d\n' 9 >$FX/git.closure; fresh=hddt-case-0002; rc=0; "$SCRIPT" prepare --operation-id $fresh --mode automatic --source-revision "$REV" --source-tree "$TREE" --canonical-remote "$REMOTE" --candidate-image-id "$CAND" --rollback-image-id "$ROLL" --moss-base-image "$BASE" --receipt-sha256 "$RECEIPT_SHA" --approval-context reviewed-fixture >/dev/null 2>&1||rc=$?; [[ $rc != 0 ]]||fail vector-accepted; }
t46(){ touch $FX/git.dirty; rc=0; prepare >/dev/null 2>&1||rc=$?; eq "$rc" 65; zero_effects; has $FX/git.log 'safe.directory='; home=${HOME:-}; [[ -z $home || ! -e $home/.gitconfig ]]||lacks "$home/.gitconfig" "$STACK"; }
t47(){
  # Current native adapter smoke: T81 owns the adversarial matrix.
  t81 happy
}
t48(){ runner=$ROOT/ops/tests/run-moss-release-tests.sh; for s in test_moss_candidate_build_contract.sh test_validate_moss_release_binding.sh test_hddt_moss.sh test_hddt_moss_recovery.sh test_hddt_adapter.sh test_hddt_mutations.sh; do has $runner "$s"; done; copy=$FX/runner; cp $runner $copy; sed -i '\|^bash ops/tests/test_hddt_moss_recovery.sh$|d' $copy; rc=0; HDDT_RUNNER_SELF_CHECK=1 bash $copy >/dev/null 2>&1||rc=$?; [[ $rc != 0 ]]||fail omitted-suite; }
t49(){ prepare; preapply_snapshot; auth; mv $STATE/authorizations/hddt-case-0001.ready $STATE/authorizations/hddt-case-0001.consumed; printf '101\tAPPLY_INTENT\tauthorization_consumed\n' >>$OP/journal.log; "$SCRIPT" recover --operation-id hddt-case-0001; state_is REJECTED_PRE_APPLY; zero_effects; [[ -f $STATE/authorizations/hddt-case-0001.consumed && ! -e $STATE/authorizations/hddt-case-0001.ready ]]; }
t50(){ mkdir -p $STACK/runtime/moss-home/ops/cutovers; printf SUCCEEDED>$STACK/runtime/moss-home/ops/cutovers/legacy; prepare; auth; run; state_is SUCCEEDED; lacks $OP/journal.log legacy; }
t51(){ hook=$BIN/drift; printf '#!/usr/bin/env bash\nprintf "DRIFT=1\\n" >>"$HDDT_STACK_ROOT/.env"\n' >$hook; chmod +x $hook; export HDDT_BEFORE_SEAL_HOOK=$hook; rc=0; prepare >/dev/null 2>&1||rc=$?; unset HDDT_BEFORE_SEAL_HOOK; eq "$rc" 65; zero_effects; rm -rf $OP; git_before=$(sha256sum $STACK/.env); receipt; prepare; auth; :>$FX/opens.log; printf 'AFTER=1\n' >>$STACK/.env; run; state_is SUCCEEDED; has $FX/opens.log "$OP/candidate.rendered.json"; lacks $FX/opens.log "$STACK/.env"; lacks $FX/opens.log "$STACK/compose.yaml"; lacks "$SCRIPT" HDDT_EXPECTED_; }
t52(){ prepare; auth; touch $FX/candidate-id-drift; run >/dev/null 2>&1||true; state_is RECOVERY_UNRESOLVED; has $OP/journal.log third_state; eq "$(grep -c compose-up $FX/mutations.log)" 1; }
t53(){ prepare; auth; touch $FX/candidate-start-drift; run >/dev/null 2>&1||true; state_is RECOVERY_UNRESOLVED; has $OP/journal.log third_state; eq "$(grep -c compose-up $FX/mutations.log)" 1; }
t54(){ prepare; auth; touch $FX/candidate-restart-drift; run >/dev/null 2>&1||true; state_is RECOVERY_UNRESOLVED; has $OP/journal.log third_state; eq "$(grep -c compose-up $FX/mutations.log)" 1; }
t55(){ prepare followable; auth; run >/dev/null 2>&1 & pid=$!; wait_state AWAITING_CONFIRMATION; [[ -f $OP/candidate-identity.json ]]||fail candidate-identity-not-sealed; jq '.Id="confirm-id-drift"' $LIVE>$LIVE.tmp; mv $LIVE.tmp $LIVE; "$SCRIPT" confirm --operation-id hddt-case-0001; wait $pid||true; state_is RECOVERY_UNRESOLVED; has $OP/journal.log third_state; eq "$(grep -c compose-up $FX/mutations.log)" 1; }
t56(){ prepare followable; auth; run >/dev/null 2>&1 & pid=$!; wait_state AWAITING_CONFIRMATION; [[ -f $OP/candidate-identity.json ]]||fail candidate-identity-not-sealed; jq '.State.StartedAt="confirm-start-drift"' $LIVE>$LIVE.tmp; mv $LIVE.tmp $LIVE; "$SCRIPT" confirm --operation-id hddt-case-0001; wait $pid||true; state_is RECOVERY_UNRESOLVED; has $OP/journal.log third_state; eq "$(grep -c compose-up $FX/mutations.log)" 1; }
t57(){ prepare followable; auth; run >/dev/null 2>&1 & pid=$!; wait_state AWAITING_CONFIRMATION; [[ -f $OP/candidate-identity.json ]]||fail candidate-identity-not-sealed; jq '.RestartCount=1' $LIVE>$LIVE.tmp; mv $LIVE.tmp $LIVE; "$SCRIPT" confirm --operation-id hddt-case-0001; wait $pid||true; state_is RECOVERY_UNRESOLVED; has $OP/journal.log third_state; eq "$(grep -c compose-up $FX/mutations.log)" 1; }
t58(){ prepare; preapply_snapshot; set_live $CAND; candidate_identity; jq '.Id="recover-id-drift"' $LIVE>$LIVE.tmp; mv $LIVE.tmp $LIVE; printf '101\tAPPLYING\tcandidate\n' >>$OP/journal.log; "$SCRIPT" recover --operation-id hddt-case-0001||true; state_is RECOVERY_UNRESOLVED; zero_effects; has $OP/journal.log third_state; }
t59(){ prepare; preapply_snapshot; set_live $CAND; candidate_identity; jq '.State.StartedAt="recover-start-drift"' $LIVE>$LIVE.tmp; mv $LIVE.tmp $LIVE; printf '101\tAPPLYING\tcandidate\n' >>$OP/journal.log; "$SCRIPT" recover --operation-id hddt-case-0001||true; state_is RECOVERY_UNRESOLVED; zero_effects; has $OP/journal.log third_state; }
t60(){ prepare; preapply_snapshot; set_live $CAND; candidate_identity; jq '.RestartCount=1' $LIVE>$LIVE.tmp; mv $LIVE.tmp $LIVE; printf '101\tAPPLYING\tcandidate\n' >>$OP/journal.log; "$SCRIPT" recover --operation-id hddt-case-0001||true; state_is RECOVERY_UNRESOLVED; zero_effects; has $OP/journal.log third_state; }

t61(){ prepare; auth; touch "$FX/live.block"; rc=0; run >"$FX/run.out" 2>&1||rc=$?; eq "$rc" 143; assert_signal_terminal REJECTED_PRE_APPLY; zero_effects; [[ -f $STATE/authorizations/hddt-case-0001.ready && ! -e $STATE/authorizations/hddt-case-0001.consumed ]]||fail preapply-authorization-consumed; }
t62(){ prepare; auth; hook=$BIN/signal-after-intent; printf '#!/usr/bin/env bash\nkill -TERM "$PPID"\n' >"$hook"; chmod +x "$hook"; export HDDT_AFTER_APPLY_INTENT_HOOK=$hook; rc=0; run >"$FX/run.out" 2>&1||rc=$?; unset HDDT_AFTER_APPLY_INTENT_HOOK; eq "$rc" 143; assert_signal_terminal ROLLED_BACK; eq "$(grep -c compose-up "$FX/mutations.log")" 0; [[ -f $STATE/authorizations/hddt-case-0001.consumed && ! -e $STATE/authorizations/hddt-case-0001.ready ]]||fail postapply-authorization-not-consumed; }
t63(){ prepare; auth; touch "$FX/apply.block"; rc=0; run >"$FX/run.out" 2>&1||rc=$?; eq "$rc" 130; assert_signal_terminal ROLLED_BACK; eq "$(grep -c compose-up "$FX/mutations.log")" 2; }
t64(){ prepare; auth; touch "$FX/probe.health-8787.fail"; rc=0; HDDT_REAL_SIGNAL_SLEEP=1 run >"$FX/run.out" 2>&1||rc=$?; eq "$rc" 143; assert_signal_terminal ROLLED_BACK; eq "$(grep -c compose-up "$FX/mutations.log")" 2; }
t65(){ prepare followable; auth; touch "$FX/signal.await"; rc=0; run >"$FX/run.out" 2>&1||rc=$?; eq "$rc" 130; assert_signal_terminal ROLLED_BACK; eq "$(grep -c compose-up "$FX/mutations.log")" 2; }
t66(){ prepare; auth; hook=$BIN/signal-third; printf '#!/usr/bin/env bash\njq '\'' .Image="sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" '\'' "$HDDT_TEST_LIVE" >"$HDDT_TEST_LIVE.tmp"; mv "$HDDT_TEST_LIVE.tmp" "$HDDT_TEST_LIVE"\nkill -TERM "$PPID"\n' >"$hook"; chmod +x "$hook"; export HDDT_TEST_LIVE=$LIVE HDDT_AFTER_APPLY_INTENT_HOOK=$hook; rc=0; run >"$FX/run.out" 2>&1||rc=$?; unset HDDT_TEST_LIVE HDDT_AFTER_APPLY_INTENT_HOOK; eq "$rc" 143; assert_signal_terminal RECOVERY_UNRESOLVED; zero_effects; has "$OP/journal.log" third_state; }
t67(){ prepare; auth; hook=$BIN/error-after-intent; printf '#!/usr/bin/env bash\nexit 73\n' >"$hook"; chmod +x "$hook"; export HDDT_AFTER_APPLY_INTENT_HOOK=$hook; rc=0; run >"$FX/run.out" 2>&1||rc=$?; unset HDDT_AFTER_APPLY_INTENT_HOOK; [[ $rc != 0 ]]||fail err-hook-succeeded; assert_signal_terminal ROLLED_BACK; zero_effects; }
t68(){ prepare followable; auth; rc=0; "$SCRIPT" confirm --operation-id hddt-case-0001 >/dev/null 2>&1||rc=$?; eq "$rc" 65; [[ ! -e $OP/control/decision.request && ! -e $OP/control/decision.consumed ]]||fail early-decision-residue; zero_effects; }
t69(){ prepare followable; load_req; jq -nc --arg request "$request_sha256" '{request_sha256:$request,confirmation_deadline_epoch:99}' >$OP/deadline.json; chmod 600 $OP/deadline.json; printf '101\tAWAITING_CONFIRMATION\tfixture\n' >>$OP/journal.log; rc=0; "$SCRIPT" confirm --operation-id hddt-case-0001 >/dev/null 2>&1||rc=$?; eq "$rc" 65; [[ ! -e $OP/control/decision.request && ! -e $OP/control/decision.consumed ]]||fail expired-decision-residue; jq -nc '{state:"SUCCEEDED",reason:"fixture",created_epoch:101}' >$OP/terminal.json; chmod 600 $OP/terminal.json; rc=0; "$SCRIPT" rollback --operation-id hddt-case-0001 >/dev/null 2>&1||rc=$?; eq "$rc" 65; [[ ! -e $OP/control/decision.request && ! -e $OP/control/decision.consumed ]]||fail terminal-decision-residue; }
t70(){ prepare followable; auth; run >/dev/null 2>&1 & pid=$!; wait_state AWAITING_CONFIRMATION; ( "$SCRIPT" confirm --operation-id hddt-case-0001 --reason first >/dev/null 2>&1 ) & a=$!; ( "$SCRIPT" rollback --operation-id hddt-case-0001 --reason second >/dev/null 2>&1 ) & b=$!; wait $a||true; wait $b||true; wait $pid||true; eq "$(find $OP/control -name 'decision.*'|wc -l|tr -d ' ')" 1; assert_signal_terminal "$(jq -r .state $OP/terminal.json)"; }
t71(){ prepare followable; auth; run >/dev/null 2>&1 & pid=$!; wait_state AWAITING_CONFIRMATION; gate=$FX/control.before; release=$FX/control.release; hook=$BIN/control-before; printf '#!/usr/bin/env bash\n: >"$HDDT_CONTROL_GATE"\nwhile [[ ! -e "$HDDT_CONTROL_RELEASE" ]]; do :; done\n' >$hook; chmod +x $hook; HDDT_CONTROL_GATE=$gate HDDT_CONTROL_RELEASE=$release HDDT_CONTROL_BEFORE_LOCK_HOOK=$hook "$SCRIPT" confirm --operation-id hddt-case-0001 >/dev/null 2>&1 & control_pid=$!; wait_file $gate; jq -nc '{state:"RECOVERY_UNRESOLVED",reason:"fixture",created_epoch:101}' >$OP/terminal.json; chmod 600 $OP/terminal.json; jq -nc --arg op hddt-case-0001 --arg s RECOVERY_UNRESOLVED --arg h "$(sha256sum $OP/terminal.json|cut -d' ' -f1)" '{operation_id:$op,state:$s,terminal_sha256:$h}' >$STATE/outbox/hddt-case-0001.ready; chmod 600 $STATE/outbox/hddt-case-0001.ready; : >$release; rc=0; wait $control_pid||rc=$?; eq "$rc" 65; kill -TERM $pid 2>/dev/null||true; wait $pid||true; [[ ! -e $OP/control/decision.request && ! -e $OP/control/decision.consumed ]]||fail terminal-wins-decision-residue; state_is RECOVERY_UNRESOLVED; eq "$(find $STATE/outbox -name "*.ready"|wc -l|tr -d " ")" 1; }
t72(){ prepare followable; auth; run >/dev/null 2>&1 & pid=$!; wait_state AWAITING_CONFIRMATION; gate=$FX/control.published; release=$FX/control.release; hook=$BIN/control-published; printf '#!/usr/bin/env bash\n: >"$HDDT_CONTROL_GATE"\nwhile [[ ! -e "$HDDT_CONTROL_RELEASE" ]]; do :; done\n' >$hook; chmod +x $hook; HDDT_CONTROL_GATE=$gate HDDT_CONTROL_RELEASE=$release HDDT_CONTROL_PUBLISHED_HOOK=$hook "$SCRIPT" confirm --operation-id hddt-case-0001 --reason raced >/dev/null 2>&1 & control_pid=$!; wait_file $gate; [[ -f $OP/control/decision.request && ! -e $OP/terminal.json ]]||fail decision-not-serialized; : >$release; wait $control_pid; wait $pid; [[ -f $OP/control/decision.consumed && ! -e $OP/control/decision.request ]]||fail decision-not-consumed; assert_signal_terminal SUCCEEDED; }
t73(){ prepare followable; preapply_snapshot; set_live $CAND; candidate_identity; load_req; jq -nc --arg request "$request_sha256" '{request_sha256:$request,confirmation_deadline_epoch:120}' >$OP/deadline.json; chmod 600 $OP/deadline.json; jq -nc --arg action rollback --arg reason fixture --arg request "$request_sha256" '{action:$action,reason:$reason,created_epoch:101,request_sha256:$request}' >$OP/control/decision.request; chmod 600 $OP/control/decision.request; printf '101\tAWAITING_CONFIRMATION\tfixture\n' >>$OP/journal.log; "$SCRIPT" recover --operation-id hddt-case-0001 >/dev/null 2>&1 & a=$!; "$SCRIPT" recover --operation-id hddt-case-0001 >/dev/null 2>&1 & b=$!; wait $a||true; wait $b||true; [[ ! -e $OP/control/decision.request && -e $OP/control/decision.consumed ]]||fail concurrent-recover-decision-residue; assert_signal_terminal ROLLED_BACK; eq "$(find $STATE/outbox -name '*.ready'|wc -l|tr -d ' ')" 1; }
cleanup_case(){
 local rc=$? pid
 trap - EXIT
 # Only reap direct jobs of this isolated case; never signal a process group or runner.
 while IFS= read -r pid; do [[ -z $pid ]] || kill -TERM "$pid" 2>/dev/null || true; done < <(jobs -pr)
 wait 2>/dev/null || true
 unset HDDT_BEFORE_SEAL_HOOK HDDT_AFTER_APPLY_INTENT_HOOK HDDT_REAL_SIGNAL_SLEEP HDDT_TEST_LIVE
 if ((rc)); then printf "FIXTURE_PRESERVED=%s CASE=%s RC=%s\\n" "$FX" "$CASE" "$rc" >&2; else rm -rf -- "$FX"; fi
 return "$rc"
}
# Oracle-only causal baselines: each has a paired, isolated semantic micro-mutant in validation.
t74(){ jq --arg r "$STATE" '.Mounts[0].Source=$r' "$LIVE" >"$LIVE.tmp"; mv "$LIVE.tmp" "$LIVE"; rc=0; prepare >/dev/null 2>&1||rc=$?; [[ $rc == 65 && ! -e "$OP" ]] || fail mount-overlap-rejected; zero_effects; }
t75(){ payload="hddt-case-0001;touch $FX/parser-pwned"; rc=0; "$SCRIPT" prepare --operation-id "$payload" --mode automatic --source-revision "$REV" --source-tree "$TREE" --canonical-remote "$REMOTE" --candidate-image-id "$CAND" --rollback-image-id "$ROLL" --moss-base-image "$BASE" --receipt-sha256 "$RECEIPT_SHA" --approval-context reviewed-fixture >/dev/null 2>&1||rc=$?; [[ $rc == 64 && ! -e "$FX/parser-pwned" ]] || fail parser-no-side-effect; zero_effects; }
t76(){ trap 'printf trapped >"$FX/nested.err"; return 73' ERR; nested_err(){ false; :; }; rc=0; set +e; nested_err >/dev/null 2>&1; rc=$?; set -e; trap - ERR; [[ $rc == 73 && $(<"$FX/nested.err") == trapped ]] || fail nested-ERR-handler; }
t77(){ cat >"$BIN/ln" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${2:-} == "$HDDT_TEST_OUTBOX" ]]; then
  if [[ ! -s $HDDT_TEST_TERMINAL ]] || [[ $(jq -r .terminal_sha256 "$1") != "$(sha256sum "$HDDT_TEST_TERMINAL"|cut -d' ' -f1)" ]]; then printf FAIL >"$HDDT_TEST_OUTBOX_GUARD"; exit 97; fi
  printf PASS >"$HDDT_TEST_OUTBOX_GUARD"
fi
/bin/ln "$@"
EOF
 chmod +x "$BIN/ln"; export HDDT_TEST_OUTBOX="$STATE/outbox/hddt-case-0001.ready" HDDT_TEST_TERMINAL="$OP/terminal.json" HDDT_TEST_OUTBOX_GUARD="$FX/outbox.guard" PATH="$BIN:$PATH"; prepare; auth; rc=0; run >"$FX/run.out" 2>&1||rc=$?; guard=$(cat "$FX/outbox.guard" 2>/dev/null||true); [[ $guard == PASS ]] || fail terminal-before-outbox; [[ $rc == 0 ]] || fail terminal-before-outbox; state_is SUCCEEDED; }
t78(){ prepare followable; auth; load_req; jq -nc --arg action confirm --arg reason fixture --arg request "$request_sha256" '{action:$action,reason:$reason,created_epoch:101,request_sha256:$request}' >"$OP/control/decision.request"; chmod 600 "$OP/control/decision.request"; rc=0; run >/dev/null 2>&1||rc=$?; [[ $rc != 0 && ! -e "$OP/control/decision.request" && -e "$OP/control/decision.consumed" && -s "$OP/terminal.json" && -s "$STATE/outbox/hddt-case-0001.ready" ]] || fail terminal-decision-classified; eq "$(grep -c compose-up "$FX/mutations.log")" 1; }
t79(){ prepare; preapply_snapshot; set_live "$CAND"; "$SCRIPT" recover --operation-id hddt-case-0001; [[ $(jq -r .state "$OP/terminal.json") == REJECTED_PRE_APPLY ]] || fail rollback-preapply-incomplete; zero_effects; eq "$(grep -c compose-up "$FX/mutations.log")" 0; }
t80(){ prepare; preapply_snapshot; set_live "$CAND"; candidate_identity; jq '.Id="recover-image-only-id"|.State.StartedAt="recover-image-only-start"|.RestartCount=1' "$LIVE" >"$LIVE.tmp"; mv "$LIVE.tmp" "$LIVE"; printf '101\tAPPLYING\tcandidate\n' >>"$OP/journal.log"; "$SCRIPT" recover --operation-id hddt-case-0001||true; [[ $(jq -r .state "$OP/terminal.json") == RECOVERY_UNRESOLVED ]] || fail recovery-image-only-third; zero_effects; has "$OP/journal.log" third_state; }
t81(){
  local mode=${1:-adversarial} rc=0 pid mutant
  [[ $mode == happy || $mode == adversarial ]] || fail t81-mode
  cat >"$BIN/http" <<'HTTP'
#!/usr/bin/env bash
set -Eeuo pipefail
method=${1:?}; url=${2:?}; body=${3-}; cookie=${4-}; accept=${5-}; fx=${FAKE_ROOT:?}; base=http://172.20.0.8:8787; session=moss-session-fixed; stream=moss-stream-fixed; workspace=moss-native-workspace; marker=moss-native-marker
[[ $cookie == "$fx/cookie" ]] || exit 9
printf '%s\t%s\t%s\t%s\t%s\n' "$method" "$url" "$body" "$cookie" "$accept" >>"$fx/http.log"
[[ "$method $url" == "POST $base/api/profile/switch" || ( -s $cookie && $(<"$cookie") == fixture-t81-cookie ) ]] || exit 9
case "$method $url" in
 "POST $base/api/profile/switch") [[ $body == '{"name":"moss"}' && ! -e $cookie ]]||exit 9; printf '%s\n' 'fixture-t81-cookie' >"$cookie"; case ${HDDT_T81_COOKIE_FAULT:-} in '') ;; missing) rm -f "$cookie";; empty) : >"$cookie";; stale) printf '%s\n' 'fixture-t81-stale' >"$cookie";; *) exit 9;; esac; printf '%s\n' '{"active":true,"name":"moss","cookie":true}';;
 "GET $base/api/profile/active") [[ -z $body ]]||exit 9; printf '%s\n' '{"name":"moss"}';;
 "POST $base/api/session/new") [[ $body == '{"profile":"moss","workspace":"moss-native-workspace"}' ]]||exit 9; : >"$fx/api.session"; printf '%s\n' '{"session":{"session_id":"moss-session-fixed"}}';;
 "POST $base/api/chat/start") [[ $body == '{"session_id":"moss-session-fixed","profile":"moss","workspace":"moss-native-workspace","message":"moss-native-marker"}' && -e $fx/api.session ]]||exit 9; : >"$fx/api.stream"; printf '%s\n' '{"stream":{"stream_id":"moss-stream-fixed","session_id":"moss-session-fixed"}}';;
 "GET $base/api/chat/stream?session_id=moss-session-fixed&stream_id=moss-stream-fixed") [[ -z $body && $accept == SSE && -e $fx/api.stream ]]||exit 9; if [[ ${HDDT_T81_SIGNAL:-0} == 1 ]]; then : >"$fx/sse.entered"; /usr/bin/sleep 5; fi; case ${HDDT_T81_SSE_VARIANT:-happy} in happy) printf '%s\n' 'data: {"event":"token","text":"moss-"}' 'data: {"event":"message","text":"native-"}' 'data: {"event":"token","text":"marker"}' 'data: {"event":"done","session":{"session_id":"moss-session-fixed"}}' 'data: {"event":"stream_end","session_id":"moss-session-fixed","stream_id":"moss-stream-fixed"}';; empty) :;; topdone) printf '%s\n' 'REACH[t81-functional-endpoint]' >&2; printf '%s\n' 'data: {"event":"token","text":"moss-native-marker"}' 'data: {"event":"done","session_id":"moss-session-fixed"}' 'data: {"event":"stream_end","session_id":"moss-session-fixed","stream_id":"moss-stream-fixed"}';; *) exit 9;; esac;;
 "GET $base/api/chat/stream/status?stream_id=moss-stream-fixed") [[ -z $body ]]||exit 9; : >"$fx/inactive"; printf '%s\n' '{"stream_id":"moss-stream-fixed","active":false}';;
 "GET $base/api/session?session_id=moss-session-fixed&messages=1") [[ -z $body && -e $fx/api.session && -e $fx/inactive ]]||exit 9; printf '%s\n' '{"session_id":"moss-session-fixed","messages":[{"id":"assistant-1","created_at":"1","role":"assistant","content":"moss-native-marker"}]}';;
 "POST $base/api/session/delete") [[ $body == '{"session_id":"moss-session-fixed"}' ]]||exit 9; rm -f "$fx/api.session" "$fx/api.stream"; printf '%s\n' '{"ok":true,"session_id":"moss-session-fixed"}';;
 "GET $base/api/session?session_id=moss-session-fixed&messages=0&poll="*) [[ -z $body && ! -e $fx/api.session && -e $fx/inactive ]]||exit 9; poll=${url##*poll=}; polls=(0 2 4 6); n=$(cat "$fx/poll.index" 2>/dev/null||printf 0); [[ $n -lt ${#polls[@]} && $poll == "${polls[$n]}" ]]||exit 9; printf '%s\n' "$((n+1))" >"$fx/poll.index"; printf '%s\n' '{"status":404,"error":"Session not found","session_id":"moss-session-fixed"}'; exit 22;;
 *) exit 9;;
esac
HTTP
  chmod +x "$BIN/http"; export HDDT_HTTP_BIN=$BIN/http HDDT_COOKIE_JAR=$FX/cookie HDDT_SSE_FILE=$FX/sse
  t81_clean(){ [[ ! -e $FX/api.session && ! -e $FX/api.stream && ! -e $FX/cookie && ! -e $FX/sse ]] || fail t81-artifact-residue; }
  t81_reset_ip(){ jq '.NetworkSettings.Networks.fixture.IPAddress="172.20.0.8"' "$LIVE">"$LIVE.tmp"; mv "$LIVE.tmp" "$LIVE"; }
  t81_no_legacy(){ ! grep -Eq '/api/(profiles|sessions|stream/status)' "$FX/http.log" || fail t81-legacy-topology; }
  t81_run(){ local variant=$1 want=$2 adapter=${3:-$ADAPTER} cookie_fault=${4:-}; : >"$FX/http.log"; rm -f "$FX/api.session" "$FX/api.stream" "$FX/cookie" "$FX/sse" "$FX/sse.entered" "$FX/poll.index" "$FX/inactive"; rc=0; HDDT_T81_SSE_VARIANT=$variant HDDT_T81_COOKIE_FAULT=$cookie_fault env -u HDDT_SCRIPT "$adapter" --container the-ai-crowd-moss-1 >"$FX/adapter.out" 2>&1 || rc=$?; if [[ $variant == topdone ]]; then has "$FX/adapter.out" 'REACH[t81-functional-endpoint]'; printf '%s\n' 'REACH[t81-functional-endpoint]' >&2; fi; if [[ $want == nonzero ]]; then [[ $rc != 0 ]] || fail t81-expected-rejection; else eq "$rc" "$want"; fi; if [[ $variant == happy && $want == 0 ]]; then [[ -s $FX/cookie && $(<"$FX/cookie") == fixture-t81-cookie ]] || fail t81-cookie-success-state; fi; rm -f "$FX/cookie" "$FX/sse"; }
  set_live "$CAND"
  t81_run happy 0
  eq "$(cat "$FX/adapter.out")" 'NATIVE_CONVERSATION=PASS CLEANUP=PASS'
  eq "$(grep -c '^POST\|^GET' "$FX/http.log")" 16
  eq "$(cat "$FX/poll.index")" 4
  [[ -e $FX/inactive ]] || fail t81-inactive-not-observed
  eq "$(awk -F '\t' '/messages=0&poll=/ {sub(/^.*poll=/,"",$2); printf "%s ",$2}' "$FX/http.log")" '0 2 4 6 '
  jq -ne --arg s moss-session-fixed '
    [{event:"done",session:{session_id:$s}},{event:"done",session_id:$s}]
    | ([.[0] | (.session|type=="object") and (.session.session_id==$s) and (has("session_id")|not)] | all)
    and ([.[1] | (.session|type=="object") and (.session.session_id==$s) and (has("session_id")|not)] | all | not)
  ' >/dev/null || fail t81-done-nested-contract
  t81_no_legacy; t81_clean
  [[ $mode == happy ]] && return 0
  t81_run empty 1; t81_clean
  t81_run topdone 1; has "$FX/adapter.out" 'REACH[t81-functional-endpoint]'; t81_clean
  for cookie_fault in missing empty stale; do t81_run happy nonzero "$ADAPTER" "$cookie_fault"; t81_clean; printf '%s\n' "T81_COOKIE $cookie_fault RED causal=true"; done
  : >"$FX/http.log"; jq '.NetworkSettings.Networks.fixture.IPAddress="127.0.0.1"' "$LIVE">"$LIVE.tmp"; mv "$LIVE.tmp" "$LIVE"
  rc=0; HDDT_T81_SSE_VARIANT=happy "$ADAPTER" --container the-ai-crowd-moss-1 >/dev/null 2>&1 || rc=$?
  eq "$rc" 78; [[ ! -s $FX/http.log ]] || fail t81-loopback-http; t81_clean
  t81_reset_ip; set_live "$CAND"; : >"$FX/http.log"; rm -f "$FX/api.session" "$FX/api.stream" "$FX/cookie" "$FX/sse" "$FX/sse.entered"
  HDDT_T81_SSE_VARIANT=happy HDDT_T81_SIGNAL=1 "$ADAPTER" --container the-ai-crowd-moss-1 >"$FX/adapter.out" 2>&1 & pid=$!
  for _ in {1..100}; do [[ -e $FX/sse.entered ]] && break; /usr/bin/sleep .01; done
  [[ -e $FX/sse.entered ]] || fail t81-signal-stream-not-entered
  kill -TERM "$pid"; rc=0; wait "$pid" || rc=$?
  eq "$rc" 143; [[ -s $FX/cookie && $(<"$FX/cookie") == fixture-t81-cookie ]] || fail t81-cookie-term-state; rm -f "$FX/cookie" "$FX/sse"; grep -Fq $'POST\thttp://172.20.0.8:8787/api/session/delete' "$FX/http.log" || fail t81-term-delete-not-reached
  t81_no_legacy; t81_clean
  # Isolated semantic micro-mutants: each must parse, reach its altered path, and turn its own oracle RED.
  mutant="$FX/adapter.mutant"; cp "$ADAPTER" "$mutant"; sed -i 's/and (\[\.\[\]|select(\.event=="done")\]\[0\]\.session\.session_id)==\$s/and (([.[]|select(.event=="done")][0].session.session_id \/\/ [.[]|select(.event=="done")][0].session_id)==$s)/' "$mutant"; bash -n "$mutant"; micro_rc=0; ( t81_run topdone 1 "$mutant" ) >"$FX/t81-mutant.out" 2>&1 || micro_rc=$?; eq "$micro_rc" 1; has "$FX/t81-mutant.out" 'ASSERT[t81]'; has "$FX/adapter.out" 'REACH[t81-functional-endpoint]'; rm -f "$FX/cookie" "$FX/sse"; t81_clean; printf '%s\n' 'T81_MUTANT top-level-done RED causal=true'
  cp "$ADAPTER" "$mutant"; sed -i '/^cleanup(){/a\  return 0' "$mutant"; bash -n "$mutant"; t81_run happy 0 "$mutant"; [[ -e $FX/api.session && -e $FX/api.stream ]] || fail t81-mutant-omit-delete-unreached; rm -f "$FX/api.session" "$FX/api.stream" "$FX/cookie" "$FX/sse"; printf '%s\n' 'T81_MUTANT omit-delete RED causal=true'
  cp "$ADAPTER" "$mutant"; sed -i 's|/api/chat/stream/status|/api/stream/status|g' "$mutant"; bash -n "$mutant"; t81_run happy 4 "$mutant"; grep -Fq '/api/stream/status' "$FX/http.log" || fail t81-mutant-legacy-status-unreached; t81_clean; printf '%s\n' 'T81_MUTANT legacy-status RED causal=true'
  cp "$ADAPTER" "$mutant"; sed -i 's|"$http" GET "$base/api/session?session_id=$session&messages=1"|: # OMIT_READBACK|' "$mutant"; bash -n "$mutant"; t81_run happy 0 "$mutant"; ! grep -Fq 'messages=1' "$FX/http.log" || fail t81-mutant-omit-readback-unreached; t81_clean; printf '%s\n' 'T81_MUTANT omit-readback RED causal=true'
  cp "$ADAPTER" "$mutant"; sed -i 's/\[\[ $ip != 127\.\* \]\] || exit 78/:/' "$mutant"; bash -n "$mutant"; : >"$FX/http.log"; jq '.NetworkSettings.Networks.fixture.IPAddress="127.0.0.1"' "$LIVE">"$LIVE.tmp"; mv "$LIVE.tmp" "$LIVE"; rc=0; HDDT_T81_SSE_VARIANT=happy "$mutant" --container the-ai-crowd-moss-1 >/dev/null 2>&1 || rc=$?; [[ $rc != 78 && -s $FX/http.log ]] || fail t81-mutant-omit-loopback-unreached; t81_reset_ip; set_live "$CAND"; t81_clean; printf '%s\n' 'T81_MUTANT omit-loopback-guard RED causal=true'
  cp "$ADAPTER" "$mutant"; sed -i "s/trap 'exit 143' TERM/trap 'trap - EXIT; exit 143' TERM/" "$mutant"; bash -n "$mutant"; : >"$FX/http.log"; rm -f "$FX/api.session" "$FX/api.stream" "$FX/cookie" "$FX/sse" "$FX/sse.entered"; HDDT_T81_SSE_VARIANT=happy HDDT_T81_SIGNAL=1 "$mutant" --container the-ai-crowd-moss-1 >/dev/null 2>&1 & pid=$!; for _ in {1..100}; do [[ -e $FX/sse.entered ]] && break; /usr/bin/sleep .01; done; [[ -e $FX/sse.entered ]] || fail t81-mutant-term-unreached; kill -TERM "$pid"; rc=0; wait "$pid" || rc=$?; [[ $rc == 143 && -e $FX/api.session && -e $FX/api.stream ]] || fail t81-mutant-omit-term-cleanup-unreached; rm -f "$FX/api.session" "$FX/api.stream" "$FX/cookie" "$FX/sse"; printf '%s\n' 'T81_MUTANT omit-TERM-cleanup RED causal=true'
}
t82(){
  local f=$STATE/build-receipts/sha256-${CAND#sha256:}.json rc=0
  jq 'del(.source_base_revision)' "$f" >"$FX/receipt.tmp"; mv "$FX/receipt.tmp" "$f"; chmod 600 "$f"; RECEIPT_SHA=$(sha256sum "$f"|cut -d' ' -f1); prepare >/dev/null 2>&1||rc=$?; eq "$rc" 65; zero_effects
  receipt; jq '.source_base_revision="ABC"' "$f" >"$FX/receipt.tmp"; mv "$FX/receipt.tmp" "$f"; chmod 600 "$f"; RECEIPT_SHA=$(sha256sum "$f"|cut -d' ' -f1); rc=0; prepare >/dev/null 2>&1||rc=$?; eq "$rc" 65; zero_effects
  receipt; touch "$FX/git.base.absent"; rc=0; prepare >/dev/null 2>&1||rc=$?; rm -f "$FX/git.base.absent"; eq "$rc" 65; zero_effects
  receipt; jq --arg rev "$REV" '.source_base_revision=$rev' "$f" >"$FX/receipt.tmp"; mv "$FX/receipt.tmp" "$f"; chmod 600 "$f"; RECEIPT_SHA=$(sha256sum "$f"|cut -d' ' -f1); rc=0; prepare >/dev/null 2>&1||rc=$?; eq "$rc" 65; zero_effects
  receipt; touch "$FX/git.base.nonancestor"; rc=0; : >"$FX/git.log"; prepare >"$FX/nonancestor.out" 2>&1||rc=$?; rm -f "$FX/git.base.nonancestor"; [[ $rc == 65 ]] || fail source-base-nonancestor-accepted; has "$FX/git.log" "merge-base><--is-ancestor><$BASE_REV><$REV>"; zero_effects
  receipt; prepare >/dev/null; auth; touch "$FX/git.base.absent"; rc=0; : >"$FX/git.log"; run >"$FX/run-base-absent.out" 2>&1||rc=$?; rm -f "$FX/git.base.absent"; eq "$rc" 65; has "$FX/git.log" "rev-parse><--verify><${BASE_REV}^{commit}>"; [[ -f $STATE/authorizations/hddt-case-0001.ready && ! -e $STATE/authorizations/hddt-case-0001.consumed ]] || fail run-source-base-consumed-authorization; zero_effects
}
t83(){
  local rc=0 auth_file=$STATE/authorizations/hddt-case-0001.ready
  prepare >/dev/null
  auth
  jq '.moss_base_image="sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"' "$auth_file" >"$FX/auth.tmp"
  mv "$FX/auth.tmp" "$auth_file"
  chmod 600 "$auth_file"
  run >"$FX/auth-base.out" 2>&1 || rc=$?
  [[ $rc == 65 ]] || fail authorization-base-binding-accepted
  [[ -f $auth_file && ! -e $STATE/authorizations/hddt-case-0001.consumed ]] || fail authorization-base-binding-consumed
  zero_effects
}
run_case(){
 CASE=${1,,}; CASE=${CASE#t}; CASE=t$CASE
 # Do not inherit controls from a prior caller; each case installs only its own hooks.
 unset HDDT_BEFORE_SEAL_HOOK HDDT_AFTER_APPLY_INTENT_HOOK HDDT_REAL_SIGNAL_SLEEP HDDT_TEST_LIVE
 fixture
 if [[ ${HDDT_KEEP_FIXTURE:-0} == 1 ]]; then
   printf 'FIXTURE=%s\n' "$FX" >&2
 else
   trap cleanup_case EXIT
 fi
 "$CASE"; printf '%s PASS\n' "${CASE^^}"
}
if [[ ${1:-} == --case ]]; then [[ $# == 2 && $2 =~ ^T(0[1-9]|[1-7][0-9]|8[0-3])$ ]]||exit 64; run_case "$2"; exit; fi
suite=${1:-core}; case $suite in core) cases=$(seq -w 1 33);; recovery) cases='34 35 36 37 38 39 40 49';; adapter) cases="47 81";; mutations) cases='41 42 43 44 45 46 48 50 51';; cas) cases=$(seq -w 52 60);; signals) cases=$(seq -w 61 67);; control) cases=$(seq -w 68 73);; oracles) cases='74 75 76 77 78 79 80 82 83';; all) cases=$(seq -w 1 83);; *) exit 64;; esac
for i in $cases; do bash "$0" --case "T$i"; done
printf 'hddt-scenarios: PASS suite=%s causal=true\n' "$suite"
