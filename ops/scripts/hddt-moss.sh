#!/usr/bin/env bash
# Host Durable Deployment Transaction (HDDT), Moss v1.
set -Eeuo pipefail
umask 077
readonly SERVICE=moss PROJECT=the-ai-crowd CONTAINER=the-ai-crowd-moss-1
readonly DEFAULT_ROOT=/mnt/user/appdata/the-ai-crowd-hddt
readonly REQUEST_KEYS='["approval_context","candidate_image_id","candidate_render_sha256","canonical_remote","confirmation_deadline_epoch","created_epoch","executor_sha256","input_aggregate_sha256","mode","moss_base_image","operation_id","request_sha256","rollback_image_id","rollback_render_sha256","source_closure_sha256","source_revision","source_tree"]'
readonly RECEIPT_KEYS='["base_image","candidate_image_id","context_sha256","created_epoch","executor_sha256","source_closure_sha256","source_remote","source_revision","source_tree","toolchain_sha256"]'
readonly AUTH_KEYS='["approval_channel","approval_id","approved_epoch","candidate_image_id","candidate_render_sha256","consumed","executor_sha256","expires_epoch","moss_base_image","operation_id","operations","request_sha256","rollback_image_id","rollback_render_sha256","source_remote","source_revision","source_tree"]'
usage(){ printf '%s\n' 'usage: hddt-moss.sh {prepare|run|confirm|rollback|recover} --operation-id ID [fields]'; }
die(){ printf 'HDDT: %s\n' "$1" >&2; exit "${2:-64}"; }
sha(){ sha256sum -- "$1"|cut -d' ' -f1; }
now(){ local n; if [[ -n ${HDDT_CLOCK_FILE:-} ]]; then read -r n <"$HDDT_CLOCK_FILE"; printf '%s\n' "$n"; else date -u +%s; fi; }
valid_id(){ [[ $1 =~ ^[a-z0-9][a-z0-9-]{7,63}$ ]]; }
valid_image(){ [[ $1 =~ ^sha256:[0-9a-f]{64}$ ]]; }
root(){ rehearsal && printf '%s\n' "${HDDT_STATE_ROOT:?}" || printf '%s\n' "$DEFAULT_ROOT"; }
stack(){ rehearsal && printf '%s\n' "${HDDT_STACK_ROOT:?}" || printf '%s\n' /mnt/user/appdata/the-ai-crowd; }
docker_bin(){ rehearsal && printf '%s\n' "${HDDT_DOCKER_BIN:?}" || printf '%s\n' /usr/bin/docker; }
rehearsal(){ [[ ${HDDT_REHEARSAL:-0} == 1 ]]; }
reject_production_overrides(){ rehearsal && return 0; local v; for v in ${!HDDT_@}; do [[ $v == HDDT_REHEARSAL ]] || die "production override rejected: $v" 65; done; }
git_bin(){ rehearsal && printf '%s\n' "${HDDT_GIT_BIN:?}" || printf '%s\n' git; }
curl_bin(){ rehearsal && printf '%s\n' "${HDDT_CURL_BIN:?}" || printf '%s\n' /usr/bin/curl; }
json_keys_exact(){ local f=$1 keys=$2; jq -e --argjson want "$keys" 'type=="object" and ((keys|sort)==($want|sort))' "$f" >/dev/null; }
regular_private(){ local p=$1 uid=${HDDT_CUSTODY_UID:-$(id -u)}; [[ -f $p && ! -L $p && $(stat -c %a -- "$p") == 600 && $(stat -c %u -- "$p") == "$uid" ]]; }
atomic_new(){ local out=$1 tmp; [[ ! -e $out ]]||return 17; tmp=$(mktemp "$(dirname "$out")/.tmp.XXXXXX"); cat >"$tmp"; chmod 600 "$tmp"; sync "$tmp"; ln "$tmp" "$out" 2>/dev/null||{ rm -f "$tmp"; return 17; }; rm -f "$tmp"; sync "$(dirname "$out")"; }
replace_atomic(){ local out=$1 tmp; tmp=$(mktemp "$(dirname "$out")/.tmp.XXXXXX"); cat >"$tmp"; chmod 600 "$tmp"; sync "$tmp"; mv -fT "$tmp" "$out"; sync "$(dirname "$out")"; }
journal(){ local op=$1 state=$2 reason=$3; printf '%s\t%s\t%s\n' "$(now)" "$state" "$reason" >>"$op/journal.log"; sync "$op/journal.log"; }
last_state(){ awk -F '\t' 'END{print $2}' "$1/journal.log"; }
deadline_valid(){ local op=$1 require_future=${2:-0} f=$op/deadline.json; regular_private "$f"&&json_keys_exact "$f" '["confirmation_deadline_epoch","request_sha256"]' || return 1; jq -e --arg request "$request_sha256" --argjson now "$(now)" --argjson future "$require_future" '.request_sha256==$request and (.confirmation_deadline_epoch|type=="number" and .>=0 and floor==.) and ($future==0 or .confirmation_deadline_epoch>$now)' "$f" >/dev/null; }
decision_valid(){ local f=$1; regular_private "$f"&&json_keys_exact "$f" '["action","created_epoch","reason","request_sha256"]' || return 1; jq -e --arg request "$request_sha256" '.request_sha256==$request and (.action=="confirm" or .action=="rollback") and (.reason|type=="string") and (.created_epoch|type=="number" and .>=0 and floor==.)' "$f" >/dev/null; }
# Caller holds op/control.lock. A decision is classified by an atomic rename before any terminal is published.
consume_decision_locked(){ local op=$1 f=$op/control/decision.request c=$op/control/decision.consumed; decision_action=none; [[ -e $f ]]||return 0; [[ ! -e $c ]]&&decision_valid "$f"||die 'decision schema/custody invalid' 65; decision_action=$(jq -r .action "$f"); mv -T -- "$f" "$c"; sync "$op/control"; }
terminal_locked(){ local op=$1 state=$2 reason=$3 r; r=$(dirname "$(dirname "$op")"); [[ ! -e $op/terminal.json ]]||return 0; consume_decision_locked "$op"; jq -nc --arg s "$state" --arg r "$reason" --argjson t "$(now)" '{state:$s,reason:$r,created_epoch:$t}'|atomic_new "$op/terminal.json"; [[ -s $op/terminal.json ]]||die 'terminal durability failure' 74; jq -nc --arg op "$(basename "$op")" --arg s "$state" --arg h "$(sha "$op/terminal.json")" '{operation_id:$op,state:$s,terminal_sha256:$h}'|atomic_new "$r/outbox/$(basename "$op").ready"||die 'terminal outbox publication failure' 74; }
terminal(){ local op=$1 state=$2 reason=$3; exec 6>"$op/control.lock"; flock -x 6; terminal_locked "$op" "$state" "$reason"; flock -u 6; }
assert_safe_tree(){
  local r=$1 real uid=${HDDT_CUSTODY_UID:-$(id -u)} p
  [[ $r == /* && ! -L $r ]]||die 'state root non-canonical or symlink' 65
  real=$(realpath -e -- "$r")||die 'state root unresolved' 65; [[ $real == "$r" ]]||die 'state root non-canonical' 65
  [[ ${HDDT_REHEARSAL:-0} == 1 && $r == /tmp/hddt-* || ${HDDT_REHEARSAL:-0} != 1 && $r == "$DEFAULT_ROOT" ]]||die 'state root boundary' 65
  p=$r; while [[ $p != /tmp && $p != / ]]; do [[ ! -L $p && $(stat -c %u -- "$p") == "$uid" && $(stat -c %a -- "$p") =~ ^7[0-7]0$ ]]||die 'state custody failed' 65; p=$(dirname "$p"); done
  local db mounts; db=$(docker_bin); mounts=$("$db" inspect --format "{{json .Mounts}}" "$CONTAINER"); jq -e --arg r "$r" 'all(.[]; .Source as $s | (($s==$r) or ($s|startswith($r+"/")) or ($r|startswith($s+"/")))|not)' <<<"$mounts" >/dev/null||die 'state root overlaps target mount' 65
}
init_root(){ local r=$1; if [[ ! -e $r ]]; then mkdir -m 700 -- "$r"; fi; assert_safe_tree "$r"; local d; for d in operations authorizations build-receipts outbox staging; do [[ -e $r/$d ]]||mkdir -m 700 "$r/$d"; [[ -d $r/$d && ! -L $r/$d ]]||die 'unsafe state subtree' 65; done; }
parse(){
 operation_id= mode= source_revision= source_tree= canonical_remote= candidate_image_id= rollback_image_id= moss_base_image= receipt_sha256= approval_context= confirmation_seconds=${HDDT_CONFIRMATION_SECONDS:-600} reason=operator
 while (($#)); do (($#>=2))||die "missing value for $1"; case $1 in
 --operation-id) operation_id=$2;; --mode) mode=$2;; --source-revision) source_revision=$2;; --source-tree) source_tree=$2;; --canonical-remote) canonical_remote=$2;; --candidate-image-id) candidate_image_id=$2;; --rollback-image-id) rollback_image_id=$2;; --moss-base-image) moss_base_image=$2;; --receipt-sha256) receipt_sha256=$2;; --approval-context) approval_context=$2;; --confirmation-seconds) confirmation_seconds=$2;; --reason) reason=$2;; *) die "unknown argument: $1";; esac; shift 2; done
 valid_id "$operation_id"||die 'invalid operation-id'
}
load_request(){
 local op=$1 f=$op/request.json canonical
 regular_private "$f"&&json_keys_exact "$f" "$REQUEST_KEYS"||die 'request schema/custody invalid' 65
 operation_id=$(jq -er '.operation_id|strings' "$f")
 mode=$(jq -er '.mode|strings' "$f")
 source_revision=$(jq -er '.source_revision|strings' "$f")
 source_tree=$(jq -er '.source_tree|strings' "$f")
 canonical_remote=$(jq -er '.canonical_remote|strings' "$f")
 candidate_image_id=$(jq -er '.candidate_image_id|strings' "$f")
 rollback_image_id=$(jq -er '.rollback_image_id|strings' "$f")
 moss_base_image=$(jq -er '.moss_base_image|strings' "$f")
 request_sha256=$(jq -er '.request_sha256|strings|select(test("^[0-9a-f]{64}$"))' "$f")
 candidate_render_sha256=$(jq -er '.candidate_render_sha256|strings|select(test("^[0-9a-f]{64}$"))' "$f")
 rollback_render_sha256=$(jq -er '.rollback_render_sha256|strings|select(test("^[0-9a-f]{64}$"))' "$f")
 executor_sha256=$(jq -er '.executor_sha256|strings|select(test("^[0-9a-f]{64}$"))' "$f")
 confirmation_deadline_epoch=$(jq -er '.confirmation_deadline_epoch|numbers|select(.>=0 and floor==.)' "$f")
 receipt_sha256=$(sha "$op/candidate-provenance.json")
 valid_id "$operation_id"&&[[ $mode == automatic || $mode == followable ]]&&valid_image "$candidate_image_id"&&valid_image "$rollback_image_id"&&[[ $candidate_image_id != "$rollback_image_id" ]]&&[[ $source_revision =~ ^[0-9a-f]{40}$ && $source_tree =~ ^[0-9a-f]{40}$ && -n $canonical_remote && -n $moss_base_image ]]||die 'request values invalid' 65
 canonical=$(jq -cS 'del(.request_sha256)' "$f")
 [[ $(printf '%s\n' "$canonical"|sha256sum|cut -d' ' -f1) == "$request_sha256" ]]||die 'request hash invalid' 65
}
check_source(){
 local sr=$1 gb head tree remote closure dirty; gb=$(git_bin)
 head=$("$gb" -c safe.directory="$sr" -C "$sr" rev-parse HEAD); tree=$("$gb" -c safe.directory="$sr" -C "$sr" rev-parse 'HEAD^{tree}'); remote=$("$gb" -c safe.directory="$sr" -C "$sr" remote get-url origin); "$gb" -c safe.directory="$sr" -C "$sr" diff --quiet||dirty=1
 [[ ${dirty:-0} == 0 && $head == "$source_revision" && $tree == "$source_tree" && $remote == "$canonical_remote" ]]||die 'source identity/cleanliness mismatch' 65
 closure=$("$gb" -c safe.directory="$sr" -C "$sr" ls-tree -r --full-tree HEAD -- \
      ops/scripts/hddt-moss.sh ops/scripts/hddt-moss-status.sh \
      ops/scripts/validate-moss-native-conversation.sh ops/scripts/build-moss-all-in-one-candidate.sh \
      ops/tests/test_hddt_moss.sh ops/tests/test_hddt_moss_recovery.sh ops/tests/test_hddt_mutations.sh \
      ops/tests/test_hddt_adapter.sh ops/tests/run-moss-release-tests.sh \
      ops/tests/test_moss_candidate_build_contract.sh | sha256sum | cut -d' ' -f1)
    [[ $closure =~ ^[0-9a-f]{64}$ ]]||die 'source closure unavailable' 65; printf '%s\n' "$closure"
}
check_receipt(){
 local r=$1 closure=$2 f="$r/build-receipts/sha256-${candidate_image_id#sha256:}.json"; regular_private "$f"&&json_keys_exact "$f" "$RECEIPT_KEYS"||die 'receipt schema/custody invalid' 65
 [[ $(sha "$f") == "$receipt_sha256" ]]||die 'receipt bytes mismatch' 65
 jq -e --arg rev "$source_revision" --arg tree "$source_tree" --arg remote "$canonical_remote" --arg image "$candidate_image_id" --arg base "$moss_base_image" --arg closure "$closure" --arg exec "$(sha "$0")" '.source_revision==$rev and .source_tree==$tree and .source_remote==$remote and .candidate_image_id==$image and .base_image==$base and .source_closure_sha256==$closure and .executor_sha256==$exec and (.context_sha256|test("^[0-9a-f]{64}$")) and (.toolchain_sha256|test("^[0-9a-f]{64}$"))' "$f" >/dev/null||die 'receipt binding mismatch' 65; printf '%s\n' "$f"
}
check_images(){ local db; db=$(docker_bin); "$db" image inspect "$moss_base_image" >/dev/null && "$db" image inspect "$candidate_image_id" >/dev/null && "$db" image inspect "$rollback_image_id" >/dev/null; }
input_manifest(){ local dir=$1; (cd "$dir"; sha256sum compose.yaml .env env/fleet.env env/moss-webui.env)|sort; }
copy_inputs(){ local sr=$1 dst=$2 f; mkdir -m 700 -p "$dst/env"; for f in compose.yaml .env env/fleet.env env/moss-webui.env; do [[ -f $sr/$f && ! -L $sr/$f ]]||die "unsafe input $f" 65; cp --reflink=never "$sr/$f" "$dst/$f"; chmod 600 "$dst/$f"; done; }
render(){ local op=$1 kind=$2 image=$3 db out; db=$(docker_bin); out="$op/$kind.rendered.json"; env -i HOME=/root PATH="$PATH" MOSS_BASE_IMAGE="$moss_base_image" MOSS_IMAGE_REF="$image" "$db" compose --env-file "$op/compose-inputs/.env" --project-directory "$op/compose-inputs" --project-name "$PROJECT" -f "$op/compose-inputs/compose.yaml" config --format json >"$out.tmp"; jq -e --arg image "$image" 'keys==["services"] and (.services|keys)==["moss"] and .services.moss.image==$image and ([paths(scalars) as $p|getpath($p)|strings]|all((contains("compose-inputs") or contains("${") or contains("env_file"))|not))' "$out.tmp" >/dev/null||die "invalid $kind render" 65; chmod 600 "$out.tmp"; sync "$out.tmp"; mv "$out.tmp" "$out"; sync "$op"; sha "$out"; }
prepare(){
 parse "$@"; reject_production_overrides; [[ $mode == automatic || $mode == followable ]]||die 'invalid mode'; valid_image "$candidate_image_id"&&valid_image "$rollback_image_id"&&[[ $candidate_image_id != "$rollback_image_id" ]]||die 'invalid image IDs'; [[ $source_revision =~ ^[0-9a-f]{40}$ && $source_tree =~ ^[0-9a-f]{40}$ && $receipt_sha256 =~ ^[0-9a-f]{64}$ && $confirmation_seconds =~ ^[0-9]+$ && -n $canonical_remote && -n $moss_base_image && -n $approval_context ]]||die 'invalid prepare fields'
 local r sr op stage closure receipt before after cand_hash roll_hash input_hash exec_hash body req_hash; r=$(root); sr=$(stack); init_root "$r"; op="$r/operations/$operation_id"
 exec 9>"$r/prepare.lock"; flock -xn 9||die 'prepare lock busy' 75
 closure=$(check_source "$sr"); check_images||die 'base or image ID unavailable' 65; receipt=$(check_receipt "$r" "$closure")
 body=$(jq -ncS --arg op "$operation_id" --arg mode "$mode" --arg rev "$source_revision" --arg tree "$source_tree" --arg remote "$canonical_remote" --arg candidate "$candidate_image_id" --arg rollback "$rollback_image_id" --arg base "$moss_base_image" --arg approval "$approval_context" --arg receipt "$receipt_sha256" '{operation_id:$op,mode:$mode,source_revision:$rev,source_tree:$tree,canonical_remote:$remote,candidate_image_id:$candidate,rollback_image_id:$rollback,moss_base_image:$base,approval_context:$approval,receipt_sha256:$receipt}')
 req_hash=$(sha256sum <<<"$body"|cut -d' ' -f1); if [[ -d $op ]]; then [[ -f $op/prepare.sha256 && $(<"$op/prepare.sha256") == "$req_hash" ]]||die 'operation payload diverges' 65; printf '%s\n' "$(jq -r .request_sha256 "$op/request.json")"; return; fi
 stage=$(mktemp -d "$r/staging/$operation_id.XXXXXX"); chmod 700 "$stage"; mkdir -m 700 "$stage/control"; trap 'rm -rf -- "${stage:-}"' INT TERM ERR EXIT
 before=$(input_manifest "$sr"); copy_inputs "$sr" "$stage/compose-inputs"; [[ -z ${HDDT_BEFORE_SEAL_HOOK:-} ]]||"$HDDT_BEFORE_SEAL_HOOK"; after=$(input_manifest "$sr"); [[ $before == "$after" ]]||die 'live inputs drifted before seal' 65
 [[ "$before" == "$(input_manifest "$stage/compose-inputs")" ]]||die 'input snapshot mismatch' 65; input_hash=$(sha256sum <<<"$before"|cut -d' ' -f1)
 cp -- "$receipt" "$stage/candidate-provenance.json"; chmod 600 "$stage/candidate-provenance.json"; [[ $(sha "$stage/candidate-provenance.json") == "$receipt_sha256" ]]||die 'receipt copy drift' 65
 cand_hash=$(render "$stage" candidate "$candidate_image_id"); roll_hash=$(render "$stage" rollback "$rollback_image_id"); exec_hash=$(sha "$0")
 body=$(jq -ncS --arg op "$operation_id" --arg mode "$mode" --arg rev "$source_revision" --arg tree "$source_tree" --arg remote "$canonical_remote" --arg candidate "$candidate_image_id" --arg rollback "$rollback_image_id" --arg base "$moss_base_image" --arg approval "$approval_context" --arg cand "$cand_hash" --arg roll "$roll_hash" --arg input "$input_hash" --arg closure "$closure" --arg exec "$exec_hash" --argjson created "$(now)" '{operation_id:$op,mode:$mode,source_revision:$rev,source_tree:$tree,canonical_remote:$remote,candidate_image_id:$candidate,rollback_image_id:$rollback,moss_base_image:$base,approval_context:$approval,candidate_render_sha256:$cand,rollback_render_sha256:$roll,input_aggregate_sha256:$input,source_closure_sha256:$closure,executor_sha256:$exec,created_epoch:$created,confirmation_deadline_epoch:0}')
 request_sha256=$(sha256sum <<<"$body"|cut -d' ' -f1); jq -cS --arg h "$request_sha256" '.+{request_sha256:$h}' <<<"$body" >"$stage/request.json"; chmod 600 "$stage/request.json"; printf '%s\n' "$req_hash" >"$stage/prepare.sha256"; chmod 600 "$stage/prepare.sha256"; : >"$stage/journal.log"; chmod 600 "$stage/journal.log"; journal "$stage" PREPARED sealed
 mv "$stage" "$op"; stage=; sync "$r/operations"; trap - INT TERM ERR EXIT; printf '%s\n' "$request_sha256"
}
validate_auth(){ local f=$1; regular_private "$f"&&json_keys_exact "$f" "$AUTH_KEYS"||return 1; jq -e --arg op "$operation_id" --arg req "$request_sha256" --arg candidate "$candidate_image_id" --arg rollback "$rollback_image_id" --arg base "$moss_base_image" --arg rev "$source_revision" --arg tree "$source_tree" --arg remote "$canonical_remote" --arg cand "$candidate_render_sha256" --arg roll "$rollback_render_sha256" --arg exec "$executor_sha256" --argjson now "$(now)" '.operation_id==$op and .request_sha256==$req and .candidate_image_id==$candidate and .rollback_image_id==$rollback and .moss_base_image==$base and .source_revision==$rev and .source_tree==$tree and .source_remote==$remote and .candidate_render_sha256==$cand and .rollback_render_sha256==$roll and .executor_sha256==$exec and .operations==["run"] and .consumed==false and (.approval_id|test("^[A-Za-z0-9._-]{8,80}$")) and (.approval_channel|length>0) and .approved_epoch<=$now and .expires_epoch>=$now' "$f" >/dev/null; }
live(){ "$(docker_bin)" inspect --format "{{json .}}" "$CONTAINER"; }
identity_fields_valid(){ jq -e '(.Id|type=="string" and length>0) and (.Image|type=="string" and length>0) and (.State.Running|type=="boolean") and (.State.Status|type=="string") and (.State.StartedAt|type=="string") and (.RestartCount|type=="number")' <<<"$1" >/dev/null; }
seal_live_snapshot(){ local op=$1 live_json=$2; identity_fields_valid "$live_json"||die 'live snapshot invalid' 65; jq -nc --arg request "$request_sha256" --argjson live "$live_json" '{request_sha256:$request,container_id:$live.Id,image_id:$live.Image,running:$live.State.Running,status:$live.State.Status,health:($live.State.Health.Status//"unavailable"),started_at:$live.State.StartedAt,restart_count:$live.RestartCount}'|atomic_new "$op/snapshot.json"||die 'snapshot already sealed' 65; }
seal_deadline(){ local op=$1 deadline=$2; jq -nc --arg request "$request_sha256" --argjson deadline "$deadline" '{request_sha256:$request,confirmation_deadline_epoch:$deadline}'|atomic_new "$op/deadline.json"||die 'deadline already sealed' 65; }
snapshot_matches(){ local op=$1 j=$2; regular_private "$op/snapshot.json"&&jq -e --arg request "$request_sha256" --argjson live "$j" '.request_sha256==$request and .container_id==$live.Id and .image_id==$live.Image and .running==$live.State.Running and .status==$live.State.Status and .health==($live.State.Health.Status//"unavailable") and .started_at==$live.State.StartedAt and .restart_count==$live.RestartCount' "$op/snapshot.json" >/dev/null; }
state_gate(){ jq -r 'if .Id==null then "absent" elif .State.Running!=true then (.State.Status//"stopped") elif (.State.Health.Status//"none")!="healthy" then (.State.Health.Status//"none") else "candidate" end' <<<"$1"; }
seal_candidate_identity(){ local op=$1 j=$2 body hash snapshot; jq -e --arg image "$candidate_image_id" '.Image==$image and .State.Running==true and .State.Status=="running" and (.State.Health.Status//"none")=="healthy"' <<<"$j" >/dev/null||return 1; snapshot=$(sha "$op/snapshot.json"); body=$(jq -ncS --arg request "$request_sha256" --arg snapshot "$snapshot" --argjson live "$j" '{request_sha256:$request,snapshot_sha256:$snapshot,container_id:$live.Id,image_id:$live.Image,started_at:$live.State.StartedAt,restart_count:$live.RestartCount,expected_running:$live.State.Running,expected_status:$live.State.Status,expected_health:($live.State.Health.Status//"unavailable")}'); hash=$(printf '%s\n' "$body"|sha256sum|cut -d' ' -f1); jq -cS --arg hash "$hash" '.+{identity_sha256:$hash}' <<<"$body"|atomic_new "$op/candidate-identity.json"; }
candidate_matches(){ local op=$1 j=$2 f=$op/candidate-identity.json body; regular_private "$f"&&json_keys_exact "$f" '["container_id","expected_health","expected_running","expected_status","identity_sha256","image_id","request_sha256","restart_count","snapshot_sha256","started_at"]' || return 1; body=$(jq -cS 'del(.identity_sha256)' "$f")||return 1; [[ $(printf '%s\n' "$body"|sha256sum|cut -d' ' -f1) == "$(jq -r .identity_sha256 "$f")" ]]||return 1; jq -e --arg request "$request_sha256" --arg snapshot "$(sha "$op/snapshot.json")" --argjson live "$j" '.request_sha256==$request and .snapshot_sha256==$snapshot and .image_id==$live.Image and .container_id==$live.Id and .started_at==$live.State.StartedAt and .restart_count==$live.RestartCount and .expected_running==$live.State.Running and .expected_status==$live.State.Status' "$f" >/dev/null; }
candidate_relation(){ candidate_matches "$1" "$2"&&printf '%s\n' candidate||printf '%s\n' third; }
rollback_relation(){ snapshot_matches "$1" "$2"&&printf '%s\n' rollback||printf '%s\n' third; }
apply_render(){ local op=$1 kind=$2 expected hashvar db; expected=$([[ $kind == candidate ]]&&printf %s "$candidate_image_id"||printf %s "$rollback_image_id"); hashvar=$([[ $kind == candidate ]]&&printf %s "$candidate_render_sha256"||printf %s "$rollback_render_sha256"); [[ $(sha "$op/$kind.rendered.json") == "$hashvar" ]]||die "$kind render hash drift" 65; jq -e --arg image "$expected" '.services.moss.image==$image' "$op/$kind.rendered.json" >/dev/null||die "$kind render binding drift" 65; db=$(docker_bin); env -i HOME=/root PATH="$PATH" "$db" compose --project-directory "$op" --project-name "$PROJECT" -f "$op/$kind.rendered.json" up -d --no-build --no-deps --force-recreate "$SERVICE"; }
probe_once(){ local op=$1 kind=$2 j state before_id before_start before_restart db cb port; j=$(live); if [[ $kind == candidate ]]; then if [[ ! -e $op/candidate-identity.json ]]; then seal_candidate_identity "$op" "$j"||{ state=$(state_gate "$j"); printf '%s\n' "$state"; return 1; }; fi; state=$(candidate_relation "$op" "$j"); else state=$(rollback_relation "$op" "$j"); fi; [[ $state == $kind || $state == candidate ]]||{ printf '%s\n' "$state"; return 1; }; state=$(state_gate "$j"); [[ $state == candidate ]]||{ printf '%s\n' "$state"; return 1; }; before_id=$(jq -er '.Id|strings|select(length>0)' <<<"$j"); before_start=$(jq -er '.State.StartedAt|strings|select(length>0)' <<<"$j"); before_restart=$(jq -er '.RestartCount|numbers' <<<"$j"); db=$(docker_bin); cb=$(curl_bin); for port in 8787 8644 8648; do "$db" exec "$before_id" /usr/bin/curl --fail --silent --show-error --max-time 5 "http://127.0.0.1:$port/health" || { printf 'health-%s\n' "$port"; return 1; }; done; "$cb" --fail --silent --show-error --max-time 5 http://127.0.0.1:8644/health || { printf '%s\n' host-health-8644; return 1; }; j=$(live); if [[ $kind == candidate ]]; then [[ $(candidate_relation "$op" "$j") == candidate ]]||{ printf '%s\n' third; return 1; }; else [[ $(rollback_relation "$op" "$j") == rollback ]]||{ printf '%s\n' third; return 1; }; fi; [[ $(jq -r .Id <<<"$j") == "$before_id" && $(jq -r .State.StartedAt <<<"$j") == "$before_start" && $(jq -r .RestartCount <<<"$j") == "$before_restart" ]]||{ printf '%s\n' restart_or_identity; return 1; }; }
rollback_live(){ local op=$1 cause=$2 j class; j=$(live); class=$(candidate_relation "$op" "$j"); case $class in candidate) ;; *) journal "$op" RECOVERY_UNRESOLVED third_state; terminal "$op" RECOVERY_UNRESOLVED third_state; return 2;; esac; journal "$op" ROLLING_BACK "$cause"; if apply_render "$op" rollback && probe_once "$op" rollback; then journal "$op" ROLLED_BACK "$cause"; terminal "$op" ROLLED_BACK "$cause"; else journal "$op" ROLLBACK_FAILED "$cause"; terminal "$op" ROLLBACK_FAILED "$cause"; return 1; fi; }
CURRENT_OP= CURRENT_PHASE= CURRENT_ROOT= HANDLER_ACTIVE=0 HANDLER_DONE=0
release_lifecycle_lock(){ flock -u 8 2>/dev/null||true; exec 8>&-; }
reacquire_lifecycle_lock(){ exec 8>"$CURRENT_ROOT/deploy.lock"; flock -xn 8; }
signal_relation(){ local j=$1; if [[ $(rollback_relation "$CURRENT_OP" "$j") == rollback ]]; then printf '%s\n' rollback; return; fi; [[ -e $CURRENT_OP/candidate-identity.json ]]||seal_candidate_identity "$CURRENT_OP" "$j"||true; candidate_relation "$CURRENT_OP" "$j"; }
finalize_interruption(){
 local origin=$1 rc=${2:-1} j relation; local reason="signal_${origin}"
 (( HANDLER_ACTIVE || HANDLER_DONE ))&&return 0
 HANDLER_ACTIVE=1; trap - INT TERM ERR EXIT
 [[ -n $CURRENT_OP && -d $CURRENT_OP && ! -e $CURRENT_OP/terminal.json ]]||{ HANDLER_DONE=1; return 0; }
 if [[ $CURRENT_PHASE == preapply ]]; then
   journal "$CURRENT_OP" REJECTED_PRE_APPLY "$reason"; terminal "$CURRENT_OP" REJECTED_PRE_APPLY "$reason"
 else
   release_lifecycle_lock
   if ! reacquire_lifecycle_lock; then
     journal "$CURRENT_OP" RECOVERY_UNRESOLVED "${reason}_lifecycle_lock_busy"; terminal "$CURRENT_OP" RECOVERY_UNRESOLVED "${reason}_lifecycle_lock_busy"
   else
     j=$(live); relation=$(signal_relation "$j")
     case $relation in
       candidate) rollback_live "$CURRENT_OP" "$reason"||true ;;
       rollback) journal "$CURRENT_OP" ROLLED_BACK "${reason}_rollback_preapply"; terminal "$CURRENT_OP" ROLLED_BACK "${reason}_rollback_preapply" ;;
       *) journal "$CURRENT_OP" RECOVERY_UNRESOLVED third_state; terminal "$CURRENT_OP" RECOVERY_UNRESOLVED third_state ;;
     esac
   fi
 fi
 HANDLER_DONE=1
 case $origin in INT) exit 130;; TERM) exit 143;; ERR) exit "$rc";; EXIT) return 0;; esac
}
run(){
 parse "$@"; reject_production_overrides; local r op auth j deadline fail= attempts=0; r=$(root); init_root "$r"; op="$r/operations/$operation_id"; [[ -d $op && ! -e $op/terminal.json ]]||die 'operation missing or terminal' 65; load_request "$op"; CURRENT_OP=$op; CURRENT_ROOT=$r; CURRENT_PHASE=preapply; trap 'finalize_interruption INT' INT; trap 'finalize_interruption TERM' TERM; trap 'finalize_interruption ERR $?' ERR; trap 'finalize_interruption EXIT $?' EXIT
 exec 8>"$r/deploy.lock"; flock -xn 8||die 'lifecycle lock busy' 75; check_source "$(stack)" >/dev/null; check_receipt "$r" "$(check_source "$(stack)")" >/dev/null; load_request "$op"; [[ $(sha "$op/candidate.rendered.json") == "$candidate_render_sha256" && $(sha "$op/rollback.rendered.json") == "$rollback_render_sha256" ]]||die 'sealed render drift' 65; j=$(live); jq -e --arg image "$rollback_image_id" '.Image==$image and .State.Running==true and .State.Status=="running" and (.State.Health.Status//"none")=="healthy"' <<<"$j" >/dev/null||{ journal "$op" REJECTED_PRE_APPLY rollback_identity_mismatch; terminal "$op" REJECTED_PRE_APPLY rollback_identity_mismatch; return 65; }; seal_live_snapshot "$op" "$j"; snapshot_matches "$op" "$j"||die "snapshot identity mismatch" 65
 auth="$r/authorizations/$operation_id.ready"; validate_auth "$auth"||{ journal "$op" REJECTED_PRE_APPLY authorization_invalid; terminal "$op" REJECTED_PRE_APPLY authorization_invalid; return 65; }; mv -T "$auth" "$r/authorizations/$operation_id.consumed"; sync "$r/authorizations"; journal "$op" APPLY_INTENT authorization_consumed; CURRENT_PHASE=mutated
 [[ -z ${HDDT_AFTER_APPLY_INTENT_HOOK:-} ]]||"$HDDT_AFTER_APPLY_INTENT_HOOK"; journal "$op" APPLYING candidate; apply_render "$op" candidate||{ rollback_live "$op" apply_failed; return 1; }; journal "$op" VERIFYING_BASE probes
 deadline=$(( $(now)+${HDDT_PROBE_SECONDS:-30} )); while ! fail=$(probe_once "$op" candidate); do attempts=$((attempts+1)); case $fail in exited|dead|unhealthy|third|restart_or_identity) rollback_live "$op" "probe_$fail"; return 1;; health-8787|health-8644|health-8648|host-health-8644) if [[ $(now) -lt $deadline ]]; then journal "$op" VERIFYING_BASE "retry_$fail"; "${HDDT_SLEEP_BIN:-sleep}" "${HDDT_SLEEP_SECONDS:-1}"; continue; fi; rollback_live "$op" "probe_deadline_probe_$fail"; return 1;; created|absent) ;; esac; [[ $(now) -ge $deadline ]]&&{ rollback_live "$op" probe_deadline; return 1; }; journal "$op" VERIFYING_BASE "retry_$fail"; "${HDDT_SLEEP_BIN:-sleep}" "${HDDT_SLEEP_SECONDS:-1}"; done
 if [[ $mode == automatic ]]; then journal "$op" VERIFYING_AUTOMATIC native; "$HDDT_NATIVE_ADAPTER" --container "$CONTAINER"||{ rollback_live "$op" native_failed; return 1; }; journal "$op" SUCCEEDED automatic; terminal "$op" SUCCEEDED automatic; return; fi
 exec 6>"$op/control.lock"; flock -x 6; [[ ! -e $op/control/decision.request && ! -e $op/control/decision.consumed ]]||{ terminal_locked "$op" RECOVERY_UNRESOLVED early_decision; flock -u 6; return 1; }; deadline=$(( $(now)+${HDDT_CONFIRMATION_SECONDS:-600} )); seal_deadline "$op" "$deadline"; journal "$op" AWAITING_CONFIRMATION awaiting; flock -u 6
 while :; do
   exec 6>"$op/control.lock"; flock -x 6
   deadline_valid "$op" 0||{ terminal_locked "$op" RECOVERY_UNRESOLVED deadline_invalid; flock -u 6; return 2; }
   deadline=$(jq -r .confirmation_deadline_epoch "$op/deadline.json")
   consume_decision_locked "$op"
   action=$decision_action
   if [[ $action != none ]]; then flock -u 6; if [[ $action == confirm ]]; then journal "$op" CONFIRMING operator; probe_once "$op" candidate >/dev/null&&{ journal "$op" SUCCEEDED confirmed; terminal "$op" SUCCEEDED confirmed; return; }; rollback_live "$op" confirm_readback_failed; return 1; fi; rollback_live "$op" requested; return; fi
   if [[ $(now) -ge $deadline ]]; then flock -u 6; rollback_live "$op" confirmation_timeout; return 1; fi
   flock -u 6; "${HDDT_SLEEP_BIN:-sleep}" "${HDDT_SLEEP_SECONDS:-1}"
 done
}
control(){
 local action=$1; shift; parse "$@"; reject_production_overrides; local r op
 r=$(root); init_root "$r"; op="$r/operations/$operation_id"
 [[ -z ${HDDT_CONTROL_BEFORE_LOCK_HOOK:-} ]]||{ rehearsal || die 'control hook unavailable' 65; "$HDDT_CONTROL_BEFORE_LOCK_HOOK"; }
 exec 7>"$op/control.lock"; flock -w "${HDDT_CONTROL_LOCK_SECONDS:-1}" 7||die 'control lock busy' 75
 [[ -d $op && ! -e $op/terminal.json ]]||die 'operation missing or terminal' 65
 load_request "$op"
 [[ $(last_state "$op") == AWAITING_CONFIRMATION ]]||die 'decision allowed only while awaiting confirmation' 65
 deadline_valid "$op" 1||die 'confirmation deadline invalid or expired' 65
 [[ ! -e $op/control/decision.request && ! -e $op/control/decision.consumed ]]||die 'decision already exists' 65
 jq -nc --arg action "$action" --arg reason "$reason" --arg request "$request_sha256" --argjson at "$(now)" '{action:$action,reason:$reason,created_epoch:$at,request_sha256:$request}'|atomic_new "$op/control/decision.request"||die 'decision publication conflict' 65
 [[ -z ${HDDT_CONTROL_PUBLISHED_HOOK:-} ]]||{ rehearsal || die 'control hook unavailable' 65; "$HDDT_CONTROL_PUBLISHED_HOOK"; }
 flock -u 7
}
recover(){
 parse "$@"; reject_production_overrides; local r op state j class decision=none deadline
 r=$(root); init_root "$r"; op="$r/operations/$operation_id"; [[ -d $op ]]||die 'operation missing' 65; load_request "$op"
 exec 8>"$r/deploy.lock"; flock -xn 8||die 'lifecycle lock busy' 75
 exec 7>"$op/control.lock"; flock -x 7
 [[ -e $op/terminal.json ]]&&{ flock -u 7; return 0; }
 state=$(last_state "$op"); consume_decision_locked "$op"; decision=$decision_action
 if [[ $state == AWAITING_CONFIRMATION ]]; then deadline_valid "$op" 0||{ terminal_locked "$op" RECOVERY_UNRESOLVED deadline_invalid; flock -u 7; return 2; }; deadline=$(jq -r .confirmation_deadline_epoch "$op/deadline.json"); fi
 flock -u 7
 [[ -f $op/snapshot.json ]]&&jq -e --arg request "$request_sha256" '.request_sha256==$request and (.container_id|type=="string") and (.image_id|type=="string") and (.running|type=="boolean") and (.status|type=="string") and (.health|type=="string") and (.started_at|type=="string") and (.restart_count|type=="number")' "$op/snapshot.json" >/dev/null||{ journal "$op" RECOVERY_UNRESOLVED snapshot_invalid; terminal "$op" RECOVERY_UNRESOLVED snapshot_invalid; return 2; }
 j=$(live); class=$(candidate_relation "$op" "$j")
 case $state in
 PREPARED|AUTHORIZED|VALIDATING|SNAPSHOTTING) journal "$op" REJECTED_PRE_APPLY recover_preapply; terminal "$op" REJECTED_PRE_APPLY recover_preapply;;
 APPLY_INTENT) if [[ $(rollback_relation "$op" "$j") == rollback ]]; then journal "$op" REJECTED_PRE_APPLY no_mutation_after_intent; terminal "$op" REJECTED_PRE_APPLY no_mutation_after_intent; elif [[ $class == candidate ]]; then probe_once "$op" candidate >/dev/null&&{ journal "$op" SUCCEEDED recovered_candidate; terminal "$op" SUCCEEDED recovered_candidate; }||rollback_live "$op" recovery_probe_failed; else journal "$op" RECOVERY_UNRESOLVED apply_intent_ambiguous; terminal "$op" RECOVERY_UNRESOLVED apply_intent_ambiguous; fi;;
 INTERRUPTED) if [[ $(rollback_relation "$op" "$j") == rollback ]]; then journal "$op" REJECTED_PRE_APPLY interrupted_before_apply; terminal "$op" REJECTED_PRE_APPLY interrupted_before_apply; elif [[ $class == candidate ]]&&probe_once "$op" candidate >/dev/null; then journal "$op" SUCCEEDED recovered_interrupted; terminal "$op" SUCCEEDED recovered_interrupted; else journal "$op" RECOVERY_UNRESOLVED interrupted_ambiguous; terminal "$op" RECOVERY_UNRESOLVED interrupted_ambiguous; fi;;
 APPLYING|VERIFYING_BASE|VERIFYING_AUTOMATIC|CONFIRMING) if [[ $decision == rollback ]]; then rollback_live "$op" recovery_requested; elif [[ $decision == confirm && $class == candidate ]]&&probe_once "$op" candidate >/dev/null; then journal "$op" SUCCEEDED recovered_confirm; terminal "$op" SUCCEEDED recovered_confirm; elif [[ $class == candidate ]]&&probe_once "$op" candidate >/dev/null; then journal "$op" SUCCEEDED recovered_candidate; terminal "$op" SUCCEEDED recovered_candidate; elif [[ $(rollback_relation "$op" "$j") == rollback ]]; then journal "$op" ROLLED_BACK recovered_rollback; terminal "$op" ROLLED_BACK recovered_rollback; else journal "$op" RECOVERY_UNRESOLVED third_state; terminal "$op" RECOVERY_UNRESOLVED third_state; fi;;
 AWAITING_CONFIRMATION) if [[ $decision == confirm && $class == candidate ]]&&probe_once "$op" candidate >/dev/null; then journal "$op" SUCCEEDED recovered_confirm; terminal "$op" SUCCEEDED recovered_confirm; elif [[ $decision == rollback || $(now) -ge $deadline ]]; then rollback_live "$op" recovery_timeout_or_decision; else die 'confirmation window still active' 75; fi;;
 ROLLING_BACK) rollback_live "$op" recovery_continue;;
 *) journal "$op" RECOVERY_UNRESOLVED unknown_state; terminal "$op" RECOVERY_UNRESOLVED unknown_state;; esac
}
[[ ${1:-} != --help && ${1:-} != -h ]]||{ usage; exit 0; }; cmd=${1:-}; shift||true
case $cmd in prepare) prepare "$@";; run) run "$@";; confirm) control confirm "$@";; rollback) control rollback "$@";; recover) recover "$@";; *) usage; exit 64;; esac
