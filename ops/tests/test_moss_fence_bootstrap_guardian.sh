#!/usr/bin/env bash
set -Eeuo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
guardian="$repo/ops/scripts/moss-fence-bootstrap-guardian.py"
tmp=$(mktemp -d)
cleanup(){ rm -rf "$tmp"; }
trap cleanup EXIT
mkdir -p "$tmp/fakebin"
cat >"$tmp/fakebin/docker" <<'FAKE'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$FAKE_CALLS"
if [[ ! -f $AUTH_CONSUMED ]]; then
  if [[ ( $1 == compose && ${!#} == config ) || $1 == inspect || "$1 ${2:-}" == 'image inspect' || ( $1 == exec && $* == *urlopen*8787/health* ) ]]; then :; else echo mutation-before-receipt >&2; exit 93; fi
fi
phase=live; [[ -f $FAKE_PHASE ]] && phase=$(<"$FAKE_PHASE")
if [[ $1 == inspect && $* == *NetworkSettings.Networks* ]]; then
 printf '%s\n' '{"NetworkID":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","Aliases":["the-ai-crowd-moss-1","moss"]}'; exit 0
fi
if [[ $1 == inspect ]]; then
 image=$FAKE_LIVE_IMAGE; [[ $phase == bootstrap ]] && image=$FAKE_BOOTSTRAP_IMAGE
 printf '%s|%s|running|healthy\n' "$FAKE_CONTAINER_ID" "$image"; exit 0
fi
if [[ "$1 ${2:-}" == 'image inspect' ]]; then printf '%s\n' "$FAKE_BOOTSTRAP_IMAGE"; exit 0; fi
if [[ $1 == compose ]]; then
 if [[ $* == *' config' ]]; then
  [[ $* == *bootstrap.override.yaml* ]] && printf 'bootstrap-render\n' || printf 'rollback-render\n'
  exit 0
 fi
 if [[ $* == *bootstrap.override.yaml* ]]; then
  if [[ ${FAKE_FAIL_BOOTSTRAP:-0} == 1 ]]; then exit 42; fi
  printf bootstrap >"$FAKE_PHASE"; exit 0
 fi
 printf rollback >"$FAKE_PHASE"; exit 0
fi
if [[ $1 == exec ]]; then
 if [[ $* == *write_drain_request* ]]; then touch "$FAKE_DRAINED"; exit 0; fi
 if [[ $* == *clear_drain_request* ]]; then rm -f "$FAKE_DRAINED"; exit 0; fi
 if [[ $* == *gateway_state.json* ]]; then
  state=running; [[ -f $FAKE_DRAINED && $phase == live ]] && state=draining
  printf '{"gateway_state":"%s","active_agents":0}\n' "$state"; exit 0
 fi
 if [[ $* == *urlopen*8787/health* ]]; then
  if [[ ${FAKE_POST_DISCONNECT_ACTIVE:-0} == 1 && -f $FAKE_DISCONNECTED ]]; then printf '%s\n' '{"status":"ok","active_runs":1,"active_streams":1}'
  elif [[ $phase == bootstrap ]]; then printf '%s\n' '{"status":"ok","active_runs":0,"active_streams":0,"admission_fenced":false}'
  else printf '%s\n' '{"status":"ok","active_runs":0,"active_streams":0}'
  fi
  exit 0
 fi
 if [[ $* == *supervisorctl* ]]; then exit 0; fi
fi
if [[ "$1 ${2:-}" == 'network disconnect' ]]; then touch "$FAKE_DISCONNECTED"; exit 0; fi
if [[ "$1 ${2:-}" == 'network connect' ]]; then rm -f "$FAKE_DISCONNECTED"; exit 0; fi
echo "unhandled fake docker: $*" >&2; exit 97
FAKE
chmod 0755 "$tmp/fakebin/docker" "$guardian"
live_image="sha256:$(printf 'a%.0s' {1..64})"
bootstrap_image="sha256:$(printf 'b%.0s' {1..64})"
container_id="$(printf 'c%.0s' {1..64})"
make_state(){
 local state=$1
 mkdir -p "$state"
 printf 'services:\n  moss:\n    image: bootstrap\n' >"$state/bootstrap.override.yaml"
 printf 'services:\n  moss:\n    image: rollback\n' >"$state/rollback.override.yaml"
 python3 - "$state" "$container_id" "$live_image" "$bootstrap_image" <<'PY'
import hashlib,json,pathlib,sys
state=pathlib.Path(sys.argv[1]); digest=lambda p:hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()
p={
 "schema":"moss-fence-bootstrap-package/v1","container":"the-ai-crowd-moss-1","service":"moss",
 "deployment_root":"/mnt/user/appdata/the-ai-crowd","compose_file":"/mnt/user/appdata/the-ai-crowd/compose.yaml","env_file":"/mnt/user/appdata/the-ai-crowd/.env",
 "expected_container_id":sys.argv[2],"expected_live_image_id":sys.argv[3],"bootstrap_image_id":sys.argv[4],
 "caddy_network_id":"d"*64,"caddy_network_aliases":["moss","the-ai-crowd-moss-1"],
 "bootstrap_override":str(state/"bootstrap.override.yaml"),"rollback_override":str(state/"rollback.override.yaml"),
 "bootstrap_override_sha256":digest(state/"bootstrap.override.yaml"),"rollback_override_sha256":digest(state/"rollback.override.yaml"),
 "compose_sha256":digest("/mnt/user/appdata/the-ai-crowd/compose.yaml"),"env_sha256":digest("/mnt/user/appdata/the-ai-crowd/.env"),
 "bootstrap_render_sha256":hashlib.sha256(b"bootstrap-render\n").hexdigest(),"rollback_render_sha256":hashlib.sha256(b"rollback-render\n").hexdigest(),
 "source_commit":"ef2c9238ce4ba48622f5f87c783caf7be8c98793"
}
(state/"package.json").write_text(json.dumps(p,indent=2,sort_keys=True)+"\n")
r={"schema":"moss-fence-bootstrap-authorization/v1","nonce":"bootstrap-test-1234567890","expires_at":"2099-01-01T00:00:00Z","package_sha256":digest(state/"package.json")}
(state/"authorization.ready.json").write_text(json.dumps(r,indent=2,sort_keys=True)+"\n")
PY
}
run_guardian(){
 local state=$1; shift
 env PATH="$tmp/fakebin:$PATH" FAKE_CALLS="$state/calls" FAKE_PHASE="$state/phase" FAKE_DRAINED="$state/drained" FAKE_DISCONNECTED="$state/disconnected" AUTH_CONSUMED="$state/authorization.consumed.json" FAKE_CONTAINER_ID="$container_id" FAKE_LIVE_IMAGE="$live_image" FAKE_BOOTSTRAP_IMAGE="$bootstrap_image" MOSS_BOOTSTRAP_TEST_LOCK_PATH="$tmp/test.lock" MOSS_BOOTSTRAP_POLL_SECONDS=0 MOSS_BOOTSTRAP_IDLE_CONFIRM_SECONDS=0 MOSS_BOOTSTRAP_TIMEOUT_SECONDS=2 "$@" "$guardian" --state "$state" --execute
}
state1="$tmp/success"; make_state "$state1"; : >"$state1/calls"
run_guardian "$state1" env
python3 - "$state1" <<'PY'
import json,pathlib,sys
s=pathlib.Path(sys.argv[1]); assert not (s/"authorization.ready.json").exists(); assert (s/"authorization.consumed.json").is_file(); assert json.loads((s/"status.json").read_text())["state"]=="bootstrap_ready"; assert (s/"phase").read_text()=="bootstrap"
PY
drain_line=$(grep -n write_drain_request "$state1/calls"|cut -d: -f1); disconnect_line=$(grep -n 'network disconnect' "$state1/calls"|cut -d: -f1); stop_line=$(grep -n 'supervisorctl.*stop moss-webui' "$state1/calls"|cut -d: -f1); up_line=$(grep -n 'compose .*bootstrap.override.yaml.* up .*force-recreate' "$state1/calls"|cut -d: -f1)
[[ $drain_line -lt $disconnect_line && $disconnect_line -lt $stop_line && $stop_line -lt $up_line ]]
set +e; run_guardian "$state1" env >/dev/null 2>&1; rc=$?; set -e; [[ $rc == 1 ]]
state2="$tmp/rollback"; make_state "$state2"; : >"$state2/calls"
set +e; run_guardian "$state2" env FAKE_FAIL_BOOTSTRAP=1 >/dev/null 2>&1; rc=$?; set -e
[[ $rc == 1 ]]
python3 - "$state2" <<'PY'
import json,pathlib,sys
s=pathlib.Path(sys.argv[1]); assert (s/"authorization.consumed.json").is_file(); assert json.loads((s/"status.json").read_text())["state"]=="rollback_ready"; assert (s/"phase").read_text()=="rollback"
PY
state3="$tmp/pretransition"; make_state "$state3"; : >"$state3/calls"
set +e; run_guardian "$state3" env FAKE_POST_DISCONNECT_ACTIVE=1 >/dev/null 2>&1; rc=$?; set -e
[[ $rc == 1 ]]
python3 - "$state3" <<'PY'
import json,pathlib,sys
s=pathlib.Path(sys.argv[1]); assert json.loads((s/"status.json").read_text())["state"]=="activation_failed_pretransition"; assert not (s/"disconnected").exists(); assert not (s/"drained").exists()
PY
grep -Fq 'network connect --alias moss --alias the-ai-crowd-moss-1 local-llm-net the-ai-crowd-moss-1' "$state3/calls"
! grep -Eq 'compose .* up ' "$state3/calls"
[[ -f $tmp/test.lock ]]
! grep -Fq -- '--force-drain' "$guardian"
! grep -Eq 'compose.*(stop|rm|down)' "$guardian"
echo moss_fence_bootstrap_guardian_behavior_ok
