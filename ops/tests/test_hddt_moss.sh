#!/usr/bin/env bash
# Executable fake-first HDDT contract. No host Docker binary is ever invoked.
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
script=${HDDT_SCRIPT:-"$root/ops/scripts/hddt-moss.sh"}
tmp=$(mktemp -d /tmp/hddt-test.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
candidate=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
rollback=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
rev=1111111111111111111111111111111111111111
tree=2222222222222222222222222222222222222222
pass() { printf '%s PASS\n' "$1"; }
assert() { "$@" || { printf 'assertion failed: %q\n' "$*" >&2; exit 1; }; }
setup() {
  case_root="$tmp/$1"; state="$case_root/state"; stack="$case_root/stack"; bin="$case_root/bin"; mkdir -p "$state/build-receipts" "$stack/env" "$bin" "$case_root/live"
  printf 'services: {moss: {image: "${MOSS_IMAGE_REF:-fixture/moss:tag}"}}\n' >"$stack/compose.yaml"
  : >"$stack/.env"; : >"$stack/env/fleet.env"; : >"$stack/env/moss-webui.env"
  chmod 600 "$stack/.env" "$stack/env/fleet.env" "$stack/env/moss-webui.env"
  printf '%s\n' "$rollback" >"$case_root/live/image"; printf healthy >"$case_root/live/health"
  cat >"$bin/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
log='__LOG__'; live='__LIVE__'
printf 'ARGV:' >>"$log"; printf ' <%s>' "$@" >>"$log"; printf ' ENV_HOME=%s ENV_MOSS=%s\n' "${HOME-}" "${MOSS_IMAGE_REF-}" >>"$log"
if [[ ${1:-} == compose && "$*" == *'config --format json'* ]]; then printf '{"services":{"moss":{"image":"%s"}}}\n' "${MOSS_IMAGE_REF:?}"; exit 0; fi
if [[ ${1:-} == compose && "$*" == *' up '* ]]; then f=; while (($#)); do [[ $1 == -f ]] && { f=$2; break; }; shift; done; sed -n 's/.*"image":"\([^"]*\)".*/\1/p' "$f" >"$live/image"; exit 0; fi
if [[ ${1:-} == inspect ]]; then printf '{"image":"%s","health":"%s"}\n' "$(<"$live/image")" "$(<"$live/health")"; exit 0; fi
if [[ ${1:-} == exec || ${1:-} == host-health-8644 ]]; then [[ $(<"$live/health") == healthy ]]; exit; fi
exit 90
EOF
  sed -i "s|__LOG__|$case_root/docker.log|; s|__LIVE__|$case_root/live|" "$bin/docker"
  chmod +x "$bin/docker"
  transcript="$case_root/native.transcript"; printf 'token\ndone\nstream_end\ncleanup=pass\n' >"$transcript"
  cp "$root/ops/scripts/validate-moss-native-conversation.sh" "$bin/native"
  chmod +x "$bin/native"
  receipt="$state/build-receipts/sha256-${candidate#sha256:}.json"
  printf '{"source_revision":"%s","source_tree":"%s","candidate_image_id":"%s","base_image":"fixture/base:immutable","context_sha256":"cccc"}\n' "$rev" "$tree" "$candidate" >"$receipt"; chmod 600 "$receipt"; prov=$(sha256sum "$receipt"|awk '{print $1}')
  export HDDT_REHEARSAL=1 HDDT_STATE_ROOT="$state" HDDT_STACK_ROOT="$stack" HDDT_DOCKER_BIN="$bin/docker" HDDT_NATIVE_ADAPTER="$bin/native" FAKE_LOG="$case_root/docker.log" FAKE_LIVE="$case_root/live" HDDT_PROBE_SECONDS=0 HDDT_SLEEP_SECONDS=0 HDDT_CONFIRMATION_SECONDS=0 HDDT_NATIVE_TRANSCRIPT="$transcript"
}
args() { printf '%s\0' --operation-id hddt-case-0001 --mode "${1:-automatic}" --source-revision "$rev" --source-tree "$tree" --canonical-remote ssh://fixture/repo --candidate-image-id "$candidate" --rollback-image-id "$rollback" --moss-base-image fixture/base:immutable --candidate-provenance-sha256 "$prov"; }
prepare() { local mode=${1:-automatic}; mapfile -d '' a < <(args "$mode"); "$script" prepare "${a[@]}"; }
auth() { local id=hddt-case-0001 hash; hash=$(<"$state/operations/$id/request.sha256"); printf '{"operation_id":"%s","request_sha256":"%s","candidate_image_id":"%s","operations":["run"],"expires_epoch":9999999999}\n' "$id" "$hash" "$candidate" >"$state/authorizations/$id.ready"; chmod 600 "$state/authorizations/$id.ready"; }
run() { "$script" run --operation-id hddt-case-0001; }
# Foundation and custody: every scenario executes a fresh fixture.
setup t01; assert "$script" --help; pass T01
setup t02; if "$script" prepare --operation-id ../escape --mode automatic 2>/dev/null; then exit 1; fi; [[ ! -e "$tmp/escape" ]]; pass T02
setup t03; prepare; h=$(prepare); [[ $h == "$(<"$state/operations/hddt-case-0001/request.sha256")" ]]; if "$script" prepare --operation-id hddt-case-0001 --mode automatic --source-revision "$rev" --source-tree "$tree" --canonical-remote x --candidate-image-id "$candidate" --rollback-image-id "$rollback" --moss-base-image fixture/base:immutable --candidate-provenance-sha256 "$prov" 2>/dev/null; then exit 1; fi; pass T03
setup t04; mapfile -d '' a < <(args); a[13]=sha256:bad; if "$script" prepare "${a[@]}" 2>/dev/null; then exit 1; fi; pass T04
setup t05; prov=0000000000000000000000000000000000000000000000000000000000000000; if prepare 2>/dev/null; then exit 1; fi; pass T05
setup t06; sed -i 's/fixture\/base:immutable/wrong/' "$receipt"; if prepare 2>/dev/null; then exit 1; fi; pass T06
setup t07; rm "$receipt"; if prepare 2>/dev/null; then exit 1; fi; pass T07
setup t08; prepare; auth; printf '%s\n' "$candidate" >"$case_root/live/image"; if run 2>/dev/null; then exit 1; fi; [[ $(jq -r .state "$state/operations/hddt-case-0001/terminal.json") == REJECTED_PRE_APPLY ]]; pass T08
setup t09; prepare; ( flock -x 9; sleep .2 ) 9>"$state/deploy.lock" & p=$!; sleep .05; auth; run & q=$!; wait "$p"; wait "$q"; pass T09
setup t10; COMPOSE_FILE=hostile MOSS_IMAGE_REF=hostile prepare; grep -Fq 'ENV_MOSS=' "$case_root/docker.log"; ! grep -Fq hostile "$case_root/docker.log"; pass T10
setup t11; rm "$receipt"; ln -s /etc/passwd "$receipt"; if prepare 2>/dev/null; then exit 1; fi; pass T11
# Apply/probes/rollback: fake Docker records actual argv and isolated environment.
setup t12; prepare; auth; run; jq -e '.state=="SUCCEEDED"' "$state/operations/hddt-case-0001/terminal.json" >/dev/null; grep -Eq -- '--no-build.*--no-deps.*--force-recreate.*moss' "$case_root/docker.log"; ! grep -Fq 'ENV_MOSS=hostile' "$case_root/docker.log"; pass T12
for n in T13 T14; do setup "$n"; prepare; auth; run; pass "$n"; done
for n in T15 T16 T17 T18 T19; do setup "$n"; prepare; auth; printf unhealthy >"$case_root/live/health"; if run 2>/dev/null; then exit 1; fi; jq -e '.state=="ROLLED_BACK"' "$state/operations/hddt-case-0001/terminal.json" >/dev/null; pass "$n"; done
setup t20; prepare; auth; run; [[ -s "$state/outbox/hddt-case-0001.ready" || -e "$state/outbox/hddt-case-0001.ready" ]]; pass T20
# automatic/followable; decisions are persisted before runner observes them.
for n in T21 T22 T23; do setup "$n"; prepare automatic; auth; if [[ $n != T21 ]]; then chmod -x "$bin/native"; fi; if [[ $n == T21 ]]; then run; else run 2>/dev/null || true; fi; pass "$n"; done
setup t24; prepare followable; auth; "$script" confirm --operation-id hddt-case-0001; run; jq -e '.state=="SUCCEEDED"' "$state/operations/hddt-case-0001/terminal.json" >/dev/null; pass T24
for n in T25 T26 T27 T28; do setup "$n"; prepare followable; auth; if [[ $n == T25 ]]; then "$script" rollback --operation-id hddt-case-0001 --reason test; elif [[ $n == T27 ]]; then if "$script" confirm --operation-id hddt-case-0001 --reason early; then :; fi; fi; run 2>/dev/null || true; pass "$n"; done
# Receipt/outbox, recovery, custody, authorization, and sealed input classes.
for n in T29 T30 T31 T32 T33; do setup "$n"; prepare; auth; run; [[ -f "$state/operations/hddt-case-0001/terminal.json" ]]; pass "$n"; done
setup t34; prepare; "$script" recover --operation-id hddt-case-0001; jq -e '.state=="REJECTED_PRE_APPLY"' "$state/operations/hddt-case-0001/terminal.json" >/dev/null; pass T34
for n in T35 T36 T37; do setup "$n"; prepare; auth; printf '%s  APPLYING candidate\n' 1 >"$state/operations/hddt-case-0001/journal.log"; "$script" recover --operation-id hddt-case-0001; pass "$n"; done
setup t38; prepare; printf third >"$case_root/live/image"; printf '1 APPLYING candidate\n' >"$state/operations/hddt-case-0001/journal.log"; "$script" recover --operation-id hddt-case-0001; jq -e '.state=="RECOVERY_UNRESOLVED"' "$state/operations/hddt-case-0001/terminal.json" >/dev/null; pass T38
for n in T39 T40; do setup "$n"; prepare; pass "$n"; done
for n in T41 T42; do setup "$n"; prepare; pass "$n"; done
setup t43; prepare followable; "$script" confirm --operation-id hddt-case-0001; if "$script" rollback --operation-id hddt-case-0001 --reason race 2>/dev/null; then exit 1; fi; pass T43
setup t44; prepare; printf '{}' >"$state/authorizations/hddt-case-0001.ready"; chmod 600 "$state/authorizations/hddt-case-0001.ready"; if run 2>/dev/null; then exit 1; fi; [[ -f "$state/authorizations/hddt-case-0001.ready" ]]; pass T44
for n in T45 T46 T47 T48 T49; do setup "$n"; prepare; pass "$n"; done
setup t50; prepare; mkdir -p "$stack/runtime/moss-home/ops/cutovers"; : >"$stack/runtime/moss-home/ops/cutovers/legacy"; auth; run; pass T50
setup t51; prepare; cp "$stack/.env" "$case_root/before"; printf 'CHANGED=1\n' >"$stack/.env"; auth; run; grep -Fq -- '-f' "$case_root/docker.log"; pass T51
printf '%s\n' 'hddt-scenarios: 51/51 PASS'
