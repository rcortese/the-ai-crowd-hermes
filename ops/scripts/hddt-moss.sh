#!/usr/bin/env bash
# Host Durable Deployment Transaction (HDDT), Moss v1.
set -Eeuo pipefail
umask 077
readonly SERVICE=moss PROJECT=the-ai-crowd CONTAINER=the-ai-crowd-moss-1
readonly -a PEER_CONTAINERS=(the-ai-crowd-jen-1 the-ai-crowd-denholm-1 the-ai-crowd-roy-1 the-ai-crowd-richmond-1 the-ai-crowd-the-elders-1)
readonly DEFAULT_ROOT=/mnt/ssd/appdata/the-ai-crowd-hddt
readonly DEFAULT_STATE_ROOT=$DEFAULT_ROOT/state
readonly DEFAULT_STACK_INPUTS=/mnt/ssd/appdata/the-ai-crowd
readonly INSTALLED_EXECUTOR=/mnt/ssd/appdata/the-ai-crowd-hddt/bin/hddt-moss.sh
readonly INSTALLED_LAUNCHER=/mnt/ssd/appdata/the-ai-crowd-hddt/bin/hddt-moss-launcher.sh
readonly REQUEST_KEYS='["approval_context","candidate_image_id","candidate_render_sha256","canonical_remote","confirmation_deadline_epoch","created_epoch","builder_sha256","executor_sha256","input_aggregate_sha256","launcher_sha256","mode","moss_base_image","operation_id","request_sha256","rollback_image_id","rollback_render_sha256","source_closure_sha256","source_revision","source_tree"]'
readonly RECEIPT_KEYS='["base_image","candidate_image_id","context_sha256","created_epoch","builder_sha256","executor_sha256","launcher_sha256","source_base_revision","source_closure_sha256","source_remote","source_revision","source_tree","toolchain_sha256"]'
readonly AUTH_KEYS='["approval_channel","approval_id","approved_epoch","candidate_image_id","candidate_render_sha256","consumed","builder_sha256","executor_sha256","expires_epoch","launcher_sha256","moss_base_image","operation_id","operations","request_sha256","rollback_image_id","rollback_render_sha256","source_remote","source_revision","source_tree"]'
usage(){ printf '%s\n' 'usage: hddt-moss.sh {prepare|run|confirm|rollback|recover|prune} [--operation-id ID fields]'; }
die(){ printf 'HDDT: %s\n' "$1" >&2; exit "${2:-64}"; }
sha(){ sha256sum -- "$1"|cut -d' ' -f1; }
now(){ local n; if [[ -n ${HDDT_CLOCK_FILE:-} ]]; then read -r n <"$HDDT_CLOCK_FILE"; printf '%s\n' "$n"; else date -u +%s; fi; }
valid_id(){ [[ $1 =~ ^[a-z0-9][a-z0-9-]{7,63}$ ]]; }
valid_image(){ [[ $1 =~ ^sha256:[0-9a-f]{64}$ ]]; }
root(){ rehearsal && printf '%s\n' "${HDDT_STATE_ROOT:?}" || printf '%s\n' "$DEFAULT_STATE_ROOT"; }
stack_inputs(){ rehearsal && printf '%s\n' "${HDDT_STACK_ROOT:?}" || printf '%s\n' "$DEFAULT_STACK_INPUTS"; }
release_source(){ rehearsal && printf '%s\n' "${HDDT_RELEASE_SOURCE_ROOT:-${HDDT_STACK_ROOT:?}}" || printf '%s\n' "$DEFAULT_ROOT/release-source"; }
stack(){ stack_inputs; }
docker_bin(){ rehearsal && printf '%s\n' "${HDDT_DOCKER_BIN:?}" || printf '%s\n' /usr/bin/docker; }
rehearsal(){ [[ ${HDDT_REHEARSAL:-0} == 1 ]]; }
reject_production_overrides(){ rehearsal && return 0; local v; for v in ${!HDDT_@}; do [[ $v == HDDT_REHEARSAL ]] || die "production override rejected: $v" 65; done; }
git_bin(){ rehearsal && printf '%s\n' "${HDDT_GIT_BIN:?}" || printf '%s\n' git; }
curl_bin(){ rehearsal && printf '%s\n' "${HDDT_CURL_BIN:?}" || printf '%s\n' /usr/bin/curl; }
json_keys_exact(){ local f=$1 keys=$2; jq -e --argjson want "$keys" 'type=="object" and ((keys|sort)==($want|sort))' "$f" >/dev/null; }
regular_private(){ local p=$1 uid; uid=$([[ ${HDDT_REHEARSAL:-0} == 1 ]] && printf %s "${HDDT_CUSTODY_UID:-$(id -u)}" || printf 0); [[ -f $p && ! -L $p && $(stat -c %a -- "$p") == 600 && $(stat -c %u -- "$p") == "$uid" ]]; }
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
 local r=$1 real uid; uid=$([[ ${HDDT_REHEARSAL:-0} == 1 ]] && printf %s "${HDDT_CUSTODY_UID:-$(id -u)}" || printf 0)
 [[ $r == /* && $r != /mnt/user/* && ! -L $r ]]||die 'state root non-canonical or symlink' 65
 real=$(realpath -e -- "$r")||die 'state root unresolved' 65; [[ $real == "$r" ]]||die 'state root non-canonical' 65
 [[ ${HDDT_REHEARSAL:-0} == 1 && $r == /tmp/hddt-*/* || ${HDDT_REHEARSAL:-0} != 1 && $r == "$DEFAULT_STATE_ROOT" ]]||die 'state root boundary' 65
 [[ $(stat -c %u -- "$r") == "$uid" && $(stat -c %a -- "$r") == 700 ]]||die 'state custody failed' 65
 local db mounts; db=$(docker_bin); mounts=$("$db" inspect --format "{{json .Mounts}}" "$CONTAINER"); jq -e --arg r "$r" 'all(.[]; .Source as $s | (($s==$r) or ($s|startswith($r+"/")) or ($r|startswith($s+"/")))|not)' <<<"$mounts" >/dev/null||die 'state root overlaps target mount' 65
}

path_overlap(){ local a=$1 b=$2; [[ $a == "$b" || $a == "$b"/* || $b == "$a"/* ]]; }
assert_fixed_paths(){
 local r=$1 release stack mounts db parent
 [[ ${HDDT_REHEARSAL:-0} == 1 ]] && return 0
 parent=$(dirname "$r"); [[ $parent == "$DEFAULT_ROOT" && $r == "$DEFAULT_STATE_ROOT" && $(release_source) == "$DEFAULT_ROOT/release-source" && $(stack_inputs) == "$DEFAULT_STACK_INPUTS" ]] || die 'production path selector rejected'
 release=$(release_source); stack=$(stack_inputs)
 [[ $release != /mnt/user/* && $stack != /mnt/user/* ]] || die 'production alias rejected' 65
 [[ -e $release && -e $stack && -e "$DEFAULT_ROOT/bin" ]] || die 'fixed production roots unresolved' 65
 [[ $(realpath -e "$release") == "$release" && $(realpath -e "$stack") == "$stack" && $(realpath -e "$DEFAULT_ROOT/bin") == "$DEFAULT_ROOT/bin" ]] || die 'fixed production roots non-canonical' 65
 local managed; for managed in "$DEFAULT_ROOT" "$DEFAULT_ROOT/bin" "$release" "$r"; do [[ ! -L $managed && $(stat -c %u "$managed") == 0 && $(stat -c %a "$managed") == 700 ]] || die 'managed custody failed' 65; done
 for managed in "$INSTALLED_EXECUTOR" "$INSTALLED_LAUNCHER"; do [[ -f $managed && ! -L $managed && $(stat -c %u "$managed") == 0 && $(stat -c %a "$managed") == 700 ]] || die 'installed byte custody failed' 65; done
 path_overlap "$r" "$stack" && die 'state/stack overlap' 65
 path_overlap "$release" "$stack" && die 'release/stack overlap' 65
 db=$(docker_bin); mounts=$("$db" inspect --format "{{json .Mounts}}" "$CONTAINER")
 jq -e --arg r "$r" --arg release "$release" --arg stack "$stack" 'all(.[]; .Source as $s | (($s==$r) or ($s==$release) or ($s==$stack) or ($s|startswith($r+"/")) or ($s|startswith($release+"/")) or ($s|startswith($stack+"/")))|not)' <<<"$mounts" >/dev/null || die 'fixed path overlaps target mount' 65
}

retention_seconds(){ local value=${HDDT_RETENTION_SECONDS:-1209600}; [[ $value =~ ^[0-9]+$ && $value -ge 86400 && $value -le 7776000 ]]||die 'invalid retention seconds' 65; printf '%s\n' "$value"; }
prune_expired(){
 local r=$1 op id retention terminal request request_hash delete_after related safe
 exec 7>"$r/retention.lock"; flock -xn 7||return 0
 for op in "$r"/operations/*; do
  [[ -d $op && ! -L $op ]]||continue; id=${op##*/}; valid_id "$id"||continue
  retention=$op/retention.json; terminal=$op/terminal.json; request=$op/request.json
  regular_private "$retention"&&regular_private "$terminal"&&regular_private "$request"||continue
  json_keys_exact "$retention" '["delete_after_epoch","request_sha256"]'||continue
  json_keys_exact "$terminal" '["created_epoch","reason","state"]'||continue
  request_hash=$(jq -er '.request_sha256|strings|select(test("^[0-9a-f]{64}$"))' "$request")||continue
  jq -e --arg request "$request_hash" --argjson now "$(now)" '.request_sha256==$request and (.delete_after_epoch|type=="number" and floor==. and .>=0 and .<=$now)' "$retention" >/dev/null||continue
  jq -e '.state=="SUCCEEDED" or .state=="ROLLED_BACK" or .state=="ROLLBACK_FAILED" or .state=="RECOVERY_UNRESOLVED" or .state=="REJECTED_PRE_APPLY"' "$terminal" >/dev/null||continue
  safe=1
  for related in "$r/authorizations/$id.ready" "$r/authorizations/$id.consumed" "$r/outbox/$id.ready"; do
   if [[ -e $related || -L $related ]]; then regular_private "$related"||{ safe=0; break; }; fi
  done
  ((safe))||continue
  rm -rf -- "$op"
  rm -f -- "$r/authorizations/$id.ready" "$r/authorizations/$id.consumed" "$r/outbox/$id.ready"
 done
 flock -u 7
}
init_root(){ local r=$1; if [[ ! -e $r ]]; then mkdir -m 700 -- "$r"; fi; assert_safe_tree "$r"; assert_fixed_paths "$r"; local d; for d in operations authorizations build-receipts outbox staging locks; do [[ -e $r/$d ]]||mkdir -m 700 "$r/$d"; [[ -d $r/$d && ! -L $r/$d && $(stat -c %a "$r/$d") == 700 ]]||die 'unsafe state subtree' 65; done; prune_expired "$r"; }
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
 builder_sha256=$(jq -er '.builder_sha256|strings|select(test("^[0-9a-f]{64}$"))' "$f")
 launcher_sha256=$(jq -er '.launcher_sha256|strings|select(test("^[0-9a-f]{64}$"))' "$f")
 executor_sha256=$(jq -er '.executor_sha256|strings|select(test("^[0-9a-f]{64}$"))' "$f")
 confirmation_deadline_epoch=$(jq -er '.confirmation_deadline_epoch|numbers|select(.>=0 and floor==.)' "$f")
 receipt_sha256=$(sha "$op/candidate-provenance.json")
 valid_id "$operation_id"&&[[ $mode == followable ]]&&valid_image "$candidate_image_id"&&valid_image "$rollback_image_id"&&[[ $candidate_image_id != "$rollback_image_id" ]]&&[[ $source_revision =~ ^[0-9a-f]{40}$ && $source_tree =~ ^[0-9a-f]{40}$ && -n $canonical_remote && -n $moss_base_image ]]||die 'request values invalid' 65
 canonical=$(jq -cS 'del(.request_sha256)' "$f")
 [[ $(printf '%s\n' "$canonical"|sha256sum|cut -d' ' -f1) == "$request_sha256" ]]||die 'request hash invalid' 65
}
check_source(){
 local sr=$1 gb head tree remote closure dirty closure_manifest path; local -a closure_paths; gb=$(git_bin)
 head=$("$gb" -c safe.directory="$sr" -C "$sr" rev-parse HEAD); tree=$("$gb" -c safe.directory="$sr" -C "$sr" rev-parse 'HEAD^{tree}'); remote=$("$gb" -c safe.directory="$sr" -C "$sr" remote get-url origin); dirty=$("$gb" -c safe.directory="$sr" -C "$sr" status --porcelain)
 [[ -z $dirty && $head == "$source_revision" && $tree == "$source_tree" && $remote == "$canonical_remote" ]]||die 'source identity/cleanliness mismatch' 65
 closure_manifest="$sr/ops/manifests/moss-release-source-closure.paths"
 [[ -f $closure_manifest && ! -L $closure_manifest ]]||die 'release source closure manifest missing or unsafe' 65
 mapfile -t closure_paths <"$closure_manifest"; ((${#closure_paths[@]} > 0))||die 'release source closure manifest empty' 65
 LC_ALL=C sort -cu "$closure_manifest"||die 'release source closure manifest must be sorted and unique' 65
 for path in "${closure_paths[@]}"; do [[ $path != /* && $path != *'..'* && -n $path ]]||die 'invalid release source closure path' 65; "$gb" -c safe.directory="$sr" -C "$sr" ls-files --error-unmatch -- "$path" >/dev/null||die 'untracked release source closure path' 65; done
 if [[ -f "$sr/ops/scripts/lib/hddt-moss-closure.sh" ]]; then closure=$(HDDT_CLOSURE_ROOT="$sr" source "$sr/ops/scripts/lib/hddt-moss-closure.sh"; hddt_source_closure "$sr"); else closure=$("$gb" -c safe.directory="$sr" -C "$sr" ls-tree -r --full-tree HEAD -- "${closure_paths[@]}" | sha256sum | cut -d' ' -f1); fi
 [[ $closure =~ ^[0-9a-f]{64}$ ]]||die 'source closure unavailable' 65; printf '%s\n' "$closure"
}
check_receipt(){
 local r=$1 checkout=$2 closure=$3 f="$r/build-receipts/sha256-${candidate_image_id#sha256:}.json" base canonical gb; regular_private "$f"&&json_keys_exact "$f" "$RECEIPT_KEYS"||die 'receipt schema/custody invalid' 65
 [[ $(sha "$f") == "$receipt_sha256" ]]||die 'receipt bytes mismatch' 65
 base=$(jq -er '.source_base_revision|strings|select(test("^[0-9a-f]{40}$"))' "$f")||die 'receipt source base invalid' 65
 gb=$(git_bin); canonical=$("$gb" -c safe.directory="$checkout" -C "$checkout" rev-parse --verify "${base}^{commit}")||die 'receipt source base unavailable' 65
 [[ $canonical == "$base" && $base != "$source_revision" ]]||die 'receipt source base mismatch' 65
 "$gb" -c safe.directory="$checkout" -C "$checkout" merge-base --is-ancestor "$base" "$source_revision"||die 'receipt source base non-ancestor' 65
 jq -e --arg rev "$source_revision" --arg tree "$source_tree" --arg remote "$canonical_remote" --arg image "$candidate_image_id" --arg base "$moss_base_image" --arg closure "$closure" --arg exec "$( [[ ${HDDT_REHEARSAL:-0} == 1 ]] && sha "$0" || sha "$INSTALLED_EXECUTOR" )" --arg builder "$(sha "$checkout/ops/scripts/build-moss-all-in-one-candidate.sh")" --arg launcher "$( [[ ${HDDT_REHEARSAL:-0} == 1 ]] && sha "$checkout/ops/scripts/hddt-moss-launcher.sh" || sha "$INSTALLED_LAUNCHER" )" '.source_revision==$rev and .source_tree==$tree and .source_remote==$remote and .candidate_image_id==$image and .base_image==$base and .source_closure_sha256==$closure and .executor_sha256==$exec and .builder_sha256==$builder and .launcher_sha256==$launcher and (.context_sha256|test("^[0-9a-f]{64}$")) and (.toolchain_sha256|test("^[0-9a-f]{64}$"))' "$f" >/dev/null||die 'receipt binding mismatch' 65; printf '%s\n' "$f"
}
check_images(){ local db; [[ $moss_base_image != "$candidate_image_id" && $moss_base_image != "$rollback_image_id" ]] || return 1; db=$(docker_bin); "$db" image inspect "$moss_base_image" >/dev/null && "$db" image inspect "$candidate_image_id" >/dev/null && "$db" image inspect "$rollback_image_id" >/dev/null; }
input_manifest(){ local dir=$1; (cd "$dir"; sha256sum compose.yaml .env env/fleet.env env/moss-webui.env env/roy.env)|sort; }
copy_inputs(){ local sr=$1 dst=$2 f; mkdir -m 700 -p "$dst/env"; for f in compose.yaml .env env/fleet.env env/moss-webui.env env/roy.env; do [[ -f $sr/$f && ! -L $sr/$f ]]||die "unsafe input $f" 65; cp --reflink=never "$sr/$f" "$dst/$f"; chmod 600 "$dst/$f"; done; }
render(){
 local op=$1 kind=$2 image=$3 inputs db out raw
 inputs="$op/$kind-inputs"
 db=$(docker_bin); out="$op/$kind.rendered.json"; raw="$out.raw"
 (cd "$inputs" && env -i HOME=/root PATH="$PATH" MOSS_IMAGE_REF="$image" "$db" compose --env-file .env --project-directory "$inputs" --project-name "$PROJECT" -f compose.yaml config --no-path-resolution --format json) >"$raw"
 jq -cS --arg image "$image" '
   def refs($value):
     if $value == null then []
     elif ($value|type)=="object" then ($value|keys)
     elif ($value|type)=="array" then [$value[] | if type=="string" then . else .source end]
     else error("unsupported reference shape") end;
   . as $root
   | $root.services.moss as $m
   | refs($m.networks // null) as $network_refs
   | refs(($m.volumes // []) | map(select(.type=="volume"))) as $volume_refs
   | refs($m.configs // null) as $config_refs
   | refs($m.secrets // null) as $secret_refs
   | {services:{moss:$m}}
     + (if ($network_refs|length)>0 then {networks:(($root.networks // {})|with_entries(select(.key as $k|$network_refs|index($k))))} else {} end)
     + (if ($volume_refs|length)>0 then {volumes:(($root.volumes // {})|with_entries(select(.key as $k|$volume_refs|index($k))))} else {} end)
     + (if ($config_refs|length)>0 then {configs:(($root.configs // {})|with_entries(select(.key as $k|$config_refs|index($k))))} else {} end)
     + (if ($secret_refs|length)>0 then {secrets:(($root.secrets // {})|with_entries(select(.key as $k|$secret_refs|index($k))))} else {} end)
 ' "$raw" >"$out.tmp" || die "cannot normalize $kind render" 65
 rm -f -- "$raw"
 jq -e --arg image "$image" '
   def refs($value):
     if $value == null then []
     elif ($value|type)=="object" then ($value|keys)
     elif ($value|type)=="array" then [$value[] | if type=="string" then . else .source end]
     else [] end;
   ((keys - ["services","networks","volumes","configs","secrets"])|length)==0
   and (.services|keys)==["moss"]
   and .services.moss.image==$image
   and (.services.moss|has("build")|not)
   and ((refs(.services.moss.networks // null) - [(.networks // {})|keys[]])|length)==0
   and ((refs((.services.moss.volumes // [])|map(select(.type=="volume"))) - [(.volumes // {})|keys[]])|length)==0
   and ((refs(.services.moss.configs // null) - [(.configs // {})|keys[]])|length)==0
   and ((refs(.services.moss.secrets // null) - [(.secrets // {})|keys[]])|length)==0
   and ([paths(scalars) as $p|getpath($p)|strings]|all((contains("candidate-inputs") or contains("rollback-inputs") or contains("${") or contains("env_file"))|not))
 ' "$out.tmp" >/dev/null||die "invalid $kind render" 65
 chmod 600 "$out.tmp"; sync "$out.tmp"; mv "$out.tmp" "$out"; sync "$op"; sha "$out"
}
prepare(){
 parse "$@"; reject_production_overrides; [[ $mode == followable ]]||die 'invalid mode'; valid_image "$candidate_image_id"&&valid_image "$rollback_image_id"&&[[ $candidate_image_id != "$rollback_image_id" ]]||die 'invalid image IDs'; [[ $source_revision =~ ^[0-9a-f]{40}$ && $source_tree =~ ^[0-9a-f]{40}$ && $receipt_sha256 =~ ^[0-9a-f]{64}$ && $confirmation_seconds =~ ^[0-9]+$ && -n $canonical_remote && -n $moss_base_image && -n $approval_context ]]||die 'invalid prepare fields'
 local r release_sr stack_sr op stage closure receipt before after candidate_before candidate_after cand_hash roll_hash input_hash exec_hash builder_hash launcher_hash body req_hash; r=$(root); release_sr=$(release_source); stack_sr=$(stack_inputs); init_root "$r"; op="$r/operations/$operation_id"
 exec 9>"$r/prepare.lock"; flock -xn 9||die 'prepare lock busy' 75
 closure=$(check_source "$release_sr"); check_images||die 'base or image ID unavailable' 65; receipt=$(check_receipt "$r" "$release_sr" "$closure")
 body=$(jq -ncS --arg op "$operation_id" --arg mode "$mode" --arg rev "$source_revision" --arg tree "$source_tree" --arg remote "$canonical_remote" --arg candidate "$candidate_image_id" --arg rollback "$rollback_image_id" --arg base "$moss_base_image" --arg approval "$approval_context" --arg receipt "$receipt_sha256" '{operation_id:$op,mode:$mode,source_revision:$rev,source_tree:$tree,canonical_remote:$remote,candidate_image_id:$candidate,rollback_image_id:$rollback,moss_base_image:$base,approval_context:$approval,receipt_sha256:$receipt}')
 req_hash=$(sha256sum <<<"$body"|cut -d' ' -f1); if [[ -d $op ]]; then [[ -f $op/prepare.sha256 && $(<"$op/prepare.sha256") == "$req_hash" ]]||die 'operation payload diverges' 65; printf '%s\n' "$(jq -r .request_sha256 "$op/request.json")"; return; fi
 stage=$(mktemp -d "$r/staging/$operation_id.XXXXXX"); chmod 700 "$stage"; mkdir -m 700 "$stage/control"; trap 'rm -rf -- "${stage:-}"' INT TERM ERR EXIT
 [[ -f $release_sr/compose.yaml && ! -L $release_sr/compose.yaml ]]||die 'candidate compose missing or unsafe' 65
 before=$(input_manifest "$stack_sr"); candidate_before=$(sha "$release_sr/compose.yaml")
 copy_inputs "$stack_sr" "$stage/rollback-inputs"
 copy_inputs "$stack_sr" "$stage/candidate-inputs"
 cp --reflink=never "$release_sr/compose.yaml" "$stage/candidate-inputs/compose.yaml"; chmod 600 "$stage/candidate-inputs/compose.yaml"
 [[ -z ${HDDT_BEFORE_SEAL_HOOK:-} ]]||"$HDDT_BEFORE_SEAL_HOOK"
 after=$(input_manifest "$stack_sr"); candidate_after=$(sha "$release_sr/compose.yaml")
 [[ $before == "$after" ]]||die 'live inputs drifted before seal' 65
 [[ $candidate_before == "$candidate_after" ]]||die 'candidate compose drifted before seal' 65
 [[ "$before" == "$(input_manifest "$stage/rollback-inputs")" ]]||die 'rollback input snapshot mismatch' 65
 [[ $(sha "$stage/candidate-inputs/compose.yaml") == "$candidate_before" ]]||die 'candidate compose snapshot mismatch' 65
 [[ $(sha "$stage/candidate-inputs/.env") == $(sha "$stack_sr/.env") && $(sha "$stage/candidate-inputs/env/fleet.env") == $(sha "$stack_sr/env/fleet.env") && $(sha "$stage/candidate-inputs/env/moss-webui.env") == $(sha "$stack_sr/env/moss-webui.env") && $(sha "$stage/candidate-inputs/env/roy.env") == $(sha "$stack_sr/env/roy.env") ]]||die 'candidate env snapshot mismatch' 65
 input_hash=$(printf 'rollback\n%s\ncandidate\n%s\n' "$(input_manifest "$stage/rollback-inputs")" "$(input_manifest "$stage/candidate-inputs")"|sha256sum|cut -d' ' -f1)
 cp -- "$receipt" "$stage/candidate-provenance.json"; chmod 600 "$stage/candidate-provenance.json"; [[ $(sha "$stage/candidate-provenance.json") == "$receipt_sha256" ]]||die 'receipt copy drift' 65
 cand_hash=$(render "$stage" candidate "$candidate_image_id"); roll_hash=$(render "$stage" rollback "$rollback_image_id"); exec_hash=$(sha "$0"); builder_hash=$(jq -r .builder_sha256 "$stage/candidate-provenance.json"); launcher_hash=$(jq -r .launcher_sha256 "$stage/candidate-provenance.json")
 body=$(jq -ncS --arg op "$operation_id" --arg mode "$mode" --arg rev "$source_revision" --arg tree "$source_tree" --arg remote "$canonical_remote" --arg candidate "$candidate_image_id" --arg rollback "$rollback_image_id" --arg base "$moss_base_image" --arg approval "$approval_context" --arg cand "$cand_hash" --arg roll "$roll_hash" --arg input "$input_hash" --arg closure "$closure" --arg exec "$exec_hash" --arg builder "$builder_hash" --arg launcher "$launcher_hash" --argjson created "$(now)" '{operation_id:$op,mode:$mode,source_revision:$rev,source_tree:$tree,canonical_remote:$remote,candidate_image_id:$candidate,rollback_image_id:$rollback,moss_base_image:$base,approval_context:$approval,candidate_render_sha256:$cand,rollback_render_sha256:$roll,input_aggregate_sha256:$input,source_closure_sha256:$closure,builder_sha256:$builder,executor_sha256:$exec,launcher_sha256:$launcher,created_epoch:$created,confirmation_deadline_epoch:0}')
 request_sha256=$(sha256sum <<<"$body"|cut -d' ' -f1); jq -cS --arg h "$request_sha256" '.+{request_sha256:$h}' <<<"$body" >"$stage/request.json"; chmod 600 "$stage/request.json"
 jq -ncS --arg request "$request_sha256" --argjson delete_after "$(( $(now)+$(retention_seconds) ))" '{request_sha256:$request,delete_after_epoch:$delete_after}' >"$stage/retention.json"; chmod 600 "$stage/retention.json"
 printf '%s\n' "$req_hash" >"$stage/prepare.sha256"; chmod 600 "$stage/prepare.sha256"; : >"$stage/journal.log"; chmod 600 "$stage/journal.log"; journal "$stage" PREPARED sealed
 mv "$stage" "$op"; stage=; sync "$r/operations"; trap - INT TERM ERR EXIT; printf '%s\n' "$request_sha256"
}
validate_auth(){ local f=$1; regular_private "$f"&&json_keys_exact "$f" "$AUTH_KEYS"||return 1; jq -e --arg op "$operation_id" --arg req "$request_sha256" --arg candidate "$candidate_image_id" --arg rollback "$rollback_image_id" --arg base "$moss_base_image" --arg rev "$source_revision" --arg tree "$source_tree" --arg remote "$canonical_remote" --arg cand "$candidate_render_sha256" --arg roll "$rollback_render_sha256" --arg builder "$builder_sha256" --arg exec "$executor_sha256" --arg launcher "$launcher_sha256" --argjson now "$(now)" '.operation_id==$op and .request_sha256==$req and .candidate_image_id==$candidate and .rollback_image_id==$rollback and .moss_base_image==$base and .source_revision==$rev and .source_tree==$tree and .source_remote==$remote and .candidate_render_sha256==$cand and .rollback_render_sha256==$roll and .builder_sha256==$builder and .executor_sha256==$exec and .launcher_sha256==$launcher and .operations==["run"] and .consumed==false and (.approval_id|test("^[A-Za-z0-9._-]{8,80}$")) and (.approval_channel|length>0) and .approved_epoch<=$now and .expires_epoch>=$now' "$f" >/dev/null; }
live(){ "$(docker_bin)" inspect --format "{{json .}}" "$CONTAINER"; }
identity_fields_valid(){ jq -e '(.Id|type=="string" and length>0) and (.Image|type=="string" and length>0) and (.State.Running|type=="boolean") and (.State.Status|type=="string") and (.State.StartedAt|type=="string") and (.RestartCount|type=="number")' <<<"$1" >/dev/null; }
seal_live_snapshot(){ local op=$1 live_json=$2; identity_fields_valid "$live_json"||die 'live snapshot invalid' 65; jq -nc --arg request "$request_sha256" --argjson live "$live_json" '{request_sha256:$request,container_id:$live.Id,image_id:$live.Image,running:$live.State.Running,status:$live.State.Status,health:($live.State.Health.Status//"unavailable"),started_at:$live.State.StartedAt,restart_count:$live.RestartCount}'|atomic_new "$op/snapshot.json"||die 'snapshot already sealed' 65; }
fleet_identity(){
 local db container live_json result='{}'; db=$(docker_bin)
 for container in "${PEER_CONTAINERS[@]}"; do
  live_json=$("$db" inspect --format "{{json .}}" "$container")||return 1
  jq -e '.Id|type=="string" and length>0' <<<"$live_json" >/dev/null||return 1
  jq -e '.Image|type=="string" and length>0' <<<"$live_json" >/dev/null||return 1
  jq -e '.State.Running==true and .State.Status=="running" and (.State.Health.Status//"none")=="healthy" and .RestartCount==0 and (.State.StartedAt|type=="string" and length>0)' <<<"$live_json" >/dev/null||return 1
  result=$(jq -cS --arg container "$container" --argjson live "$live_json" '.+{($container):{container_id:$live.Id,image_id:$live.Image,started_at:$live.State.StartedAt,restart_count:$live.RestartCount,running:$live.State.Running,status:$live.State.Status,health:($live.State.Health.Status//"unavailable")}}' <<<"$result")||return 1
 done
 printf '%s\n' "$result"
}
seal_fleet_snapshot(){ local op=$1 peers; peers=$(fleet_identity)||die 'peer fleet preimage invalid' 65; jq -ncS --arg request "$request_sha256" --argjson peers "$peers" '{request_sha256:$request,peers:$peers}'|atomic_new "$op/fleet-snapshot.json"||die 'fleet snapshot already sealed' 65; }
fleet_matches(){ local op=$1 current; regular_private "$op/fleet-snapshot.json"||return 1; current=$(fleet_identity)||return 1; jq -e --arg request "$request_sha256" --argjson current "$current" '.request_sha256==$request and .peers==$current and (.peers|length)==5' "$op/fleet-snapshot.json" >/dev/null; }
a2a_probe(){
 local nonce="hddt-${request_sha256:0:24}" bin code db
 if rehearsal; then bin=${HDDT_A2A_BIN:?}; "$bin" --from moss --to jen --nonce "$nonce" && "$bin" --from jen --to moss --nonce "$nonce"; return; fi
 code='import asyncio,json,sys; from tools.persona_rpc import _handle_persona_rpc; target,nonce=sys.argv[1:]; question="Reply with exactly "+nonce+" and nothing else."; receipt=json.loads(asyncio.run(_handle_persona_rpc({"target":target,"question":question}))); raise SystemExit(0 if receipt.get("status")=="ok" and receipt.get("answer_text")==nonce else 1)'
 db=$(docker_bin)
 "$db" exec "$CONTAINER" /usr/bin/env PYTHONPATH=/opt/hermes python3 -c "$code" jen "$nonce" >/dev/null
 "$db" exec the-ai-crowd-jen-1 /usr/bin/env PYTHONPATH=/opt/hermes python3 -c "$code" moss "$nonce" >/dev/null
}
seal_deadline(){ local op=$1 deadline=$2; jq -nc --arg request "$request_sha256" --argjson deadline "$deadline" '{request_sha256:$request,confirmation_deadline_epoch:$deadline}'|atomic_new "$op/deadline.json"||die 'deadline already sealed' 65; }
snapshot_matches(){ local op=$1 j=$2; regular_private "$op/snapshot.json"&&jq -e --arg request "$request_sha256" --argjson live "$j" '.request_sha256==$request and .container_id==$live.Id and .image_id==$live.Image and .running==$live.State.Running and .status==$live.State.Status and .health==($live.State.Health.Status//"unavailable") and .started_at==$live.State.StartedAt and .restart_count==0 and $live.RestartCount==0 and .restart_count==$live.RestartCount' "$op/snapshot.json" >/dev/null; }
state_gate(){ jq -r 'if .Id==null then "absent" elif .State.Running!=true then (.State.Status//"stopped") elif (.State.Health.Status//"none")!="healthy" then (.State.Health.Status//"none") elif (.RestartCount//-1)!=0 then "restart_count" else "candidate" end' <<<"$1"; }
seal_candidate_identity(){ local op=$1 j=$2 body hash snapshot; jq -e --arg image "$candidate_image_id" '.Image==$image and .State.Running==true and .State.Status=="running" and (.State.Health.Status//"none")=="healthy" and (.RestartCount|type=="number")' <<<"$j" >/dev/null||return 1; snapshot=$(sha "$op/snapshot.json"); body=$(jq -ncS --arg request "$request_sha256" --arg snapshot "$snapshot" --argjson live "$j" '{request_sha256:$request,snapshot_sha256:$snapshot,container_id:$live.Id,image_id:$live.Image,started_at:$live.State.StartedAt,restart_count:$live.RestartCount,expected_running:$live.State.Running,expected_status:$live.State.Status,expected_health:($live.State.Health.Status//"unavailable")}'); hash=$(printf '%s\n' "$body"|sha256sum|cut -d' ' -f1); jq -cS --arg hash "$hash" '.+{identity_sha256:$hash}' <<<"$body"|atomic_new "$op/candidate-identity.json"||return 1; [[ $(state_gate "$j") == candidate ]]; }
candidate_recovery_matches(){ local op=$1 j=$2 f=$op/candidate-identity.json body; regular_private "$f"&&json_keys_exact "$f" '["container_id","expected_health","expected_running","expected_status","identity_sha256","image_id","request_sha256","restart_count","snapshot_sha256","started_at"]' || return 1; body=$(jq -cS 'del(.identity_sha256)' "$f")||return 1; [[ $(printf '%s\n' "$body"|sha256sum|cut -d' ' -f1) == "$(jq -r .identity_sha256 "$f")" ]]||return 1; jq -e --arg request "$request_sha256" --arg snapshot "$(sha "$op/snapshot.json")" --argjson live "$j" '.request_sha256==$request and .snapshot_sha256==$snapshot and .image_id==$live.Image and .container_id==$live.Id and .started_at==$live.State.StartedAt and .restart_count==$live.RestartCount and .expected_running==$live.State.Running and .expected_status==$live.State.Status' "$f" >/dev/null; }
candidate_matches(){ local op=$1 j=$2; candidate_recovery_matches "$op" "$j"&&jq -e --argjson live "$j" '.restart_count==0 and $live.RestartCount==0' "$op/candidate-identity.json" >/dev/null; }
candidate_relation(){ candidate_matches "$1" "$2"&&printf '%s\n' candidate||printf '%s\n' third; }
candidate_recovery_relation(){ candidate_recovery_matches "$1" "$2"&&printf '%s\n' candidate||printf '%s\n' third; }
rollback_relation(){ snapshot_matches "$1" "$2"&&printf '%s\n' rollback||printf '%s\n' third; }
apply_render(){ local op=$1 kind=$2 expected hashvar db; expected=$([[ $kind == candidate ]]&&printf %s "$candidate_image_id"||printf %s "$rollback_image_id"); hashvar=$([[ $kind == candidate ]]&&printf %s "$candidate_render_sha256"||printf %s "$rollback_render_sha256"); [[ $(sha "$op/$kind.rendered.json") == "$hashvar" ]]||die "$kind render hash drift" 65; jq -e --arg image "$expected" '.services.moss.image==$image' "$op/$kind.rendered.json" >/dev/null||die "$kind render binding drift" 65; db=$(docker_bin); env -i HOME=/root PATH="$PATH" "$db" compose --project-directory "$(stack_inputs)" --project-name "$PROJECT" -f "$op/$kind.rendered.json" up -d --no-build --no-deps --force-recreate "$SERVICE"; }
probe_once(){
 local op=$1 kind=$2 j state before_id before_start before_restart db cb port
 j=$(live)
 if [[ $kind == candidate ]]; then
  if [[ ! -e $op/candidate-identity.json ]]; then seal_candidate_identity "$op" "$j"||{ state=$(state_gate "$j"); printf '%s\n' "$state"; return 1; }; fi
  state=$(candidate_relation "$op" "$j")
 else state=$(rollback_relation "$op" "$j"); fi
 [[ $state == $kind || $state == candidate ]]||{ printf '%s\n' "$state"; return 1; }
 state=$(state_gate "$j"); [[ $state == candidate ]]||{ printf '%s\n' "$state"; return 1; }
 before_id=$(jq -er '.Id|strings|select(length>0)' <<<"$j"); before_start=$(jq -er '.State.StartedAt|strings|select(length>0)' <<<"$j"); before_restart=$(jq -er '.RestartCount|numbers' <<<"$j")
 db=$(docker_bin); cb=$(curl_bin)
 for port in 8787 8644 8648; do "$db" exec "$before_id" /usr/bin/curl --fail --silent --show-error --max-time 5 "http://127.0.0.1:$port/health" || { printf 'health-%s\n' "$port"; return 1; }; done
 "$cb" --fail --silent --show-error --max-time 5 http://127.0.0.1:8644/health || { printf '%s\n' host-health-8644; return 1; }
 j=$(live)
 if [[ $kind == candidate ]]; then [[ $(candidate_relation "$op" "$j") == candidate ]]||{ printf '%s\n' third; return 1; }; else [[ $(rollback_relation "$op" "$j") == rollback ]]||{ printf '%s\n' third; return 1; }; fi
 [[ $(jq -r .Id <<<"$j") == "$before_id" && $(jq -r .State.StartedAt <<<"$j") == "$before_start" && $(jq -r .RestartCount <<<"$j") == "$before_restart" ]]||{ printf '%s\n' restart_or_identity; return 1; }
 fleet_matches "$op"||{ printf '%s\n' peer_drift; return 1; }
 a2a_probe||{ printf '%s\n' a2a; return 1; }
}
rollback_live(){ local op=$1 cause=$2 j class; j=$(live); class=$(candidate_recovery_relation "$op" "$j"); case $class in candidate) ;; *) journal "$op" RECOVERY_UNRESOLVED third_state; terminal "$op" RECOVERY_UNRESOLVED third_state; return 2;; esac; journal "$op" ROLLING_BACK "$cause"; if apply_render "$op" rollback && probe_once "$op" rollback; then journal "$op" ROLLED_BACK "$cause"; terminal "$op" ROLLED_BACK "$cause"; else journal "$op" ROLLBACK_FAILED "$cause"; terminal "$op" ROLLBACK_FAILED "$cause"; return 1; fi; }
CURRENT_OP= CURRENT_PHASE= CURRENT_ROOT= HANDLER_ACTIVE=0 HANDLER_DONE=0
release_lifecycle_lock(){ flock -u 8 2>/dev/null||true; exec 8>&-; }
reacquire_lifecycle_lock(){ exec 8>"$CURRENT_ROOT/deploy.lock"; flock -xn 8; }
signal_relation(){ local j=$1; if [[ $(rollback_relation "$CURRENT_OP" "$j") == rollback ]]; then printf '%s\n' rollback; return 0; fi; [[ -e $CURRENT_OP/candidate-identity.json ]]||seal_candidate_identity "$CURRENT_OP" "$j"||true; candidate_recovery_relation "$CURRENT_OP" "$j"; }
finalize_interruption(){
 local origin=$1 rc=${2:-1} j relation; local reason="signal_${origin}"
 (( HANDLER_ACTIVE || HANDLER_DONE ))&&return 0
 HANDLER_ACTIVE=1; write_runner_exit "$rc"; trap - INT TERM ERR EXIT
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
classify_legacy(){ local r=$1 opid=$2 op f; op="$r/operations/$opid"; f="$op/request.json"; [[ -d $op && -f $f ]] || return 0; if ! json_keys_exact "$f" "$REQUEST_KEYS" || [[ $(jq -r '.mode//""' "$f" 2>/dev/null) != followable ]]; then printf 'RECOVERY_UNRESOLVED legacy_schema\n' >&2; return 65; fi; }
runner_started_valid(){ local f=$1 pid token sid pgid; [[ -f $f ]] || return 1; pid=$(jq -er .pid "$f")||return 1; token=$(jq -er .start_token "$f")||return 1; sid=$(jq -er .sid "$f")||return 1; pgid=$(jq -er .pgid "$f")||return 1; [[ -r /proc/$pid/stat ]]||return 1; [[ $(awk '{print $22}' /proc/$pid/stat) == "$token" && $(ps -o sid= -p "$pid"|tr -d ' ') == "$sid" && $(ps -o pgid= -p "$pid"|tr -d ' ') == "$pgid" ]]; }
write_runner_exit(){ local rc=${1:-0} op=${CURRENT_OP:-}; [[ ${HDDT_REHEARSAL:-0} != 1 && -n $op && -d $op && -n ${request_sha256:-} ]] || return 0; [[ -e $op/runner.exit.json ]] && return 0; jq -ncS --arg request "$request_sha256" --argjson pid "$$" --argjson code "$rc" --arg terminal "$( [[ -f $op/terminal.json ]] && sha "$op/terminal.json" || printf '' )" '{request_sha256:$request,pid:$pid,exit_code:$code,terminal_sha256:(if $terminal=="" then null else $terminal end),exit_epoch:now}' | atomic_new "$op/runner.exit.json" || true; }
run(){
 parse "$@"; reject_production_overrides; local r op auth j deadline fail= attempts=0; r=$(root); classify_legacy "$r" "$operation_id"; init_root "$r"; op="$r/operations/$operation_id"; [[ -d $op && ! -e $op/terminal.json ]]||die 'operation missing or terminal' 65; load_request "$op"; CURRENT_OP=$op; CURRENT_ROOT=$r; CURRENT_PHASE=preapply; trap 'finalize_interruption INT' INT; trap 'finalize_interruption TERM' TERM; trap 'finalize_interruption ERR $?' ERR; trap 'finalize_interruption EXIT $?' EXIT
 exec 8>"$r/deploy.lock"; flock -xn 8||die 'lifecycle lock busy' 75; local release_sr closure; release_sr=$(release_source); closure=$(check_source "$release_sr"); check_receipt "$r" "$release_sr" "$closure" >/dev/null; load_request "$op"; if [[ ${HDDT_REHEARSAL:-0} != 1 ]]; then
   if [[ ! -e "$op/runner.started.json" && -f "$op/runner.launch.json" ]]; then token=$(awk '{print $22}' "/proc/$$/stat"); sid=$(ps -o sid= -p $$|tr -d ' '); pgid=$(ps -o pgid= -p $$|tr -d ' '); jq -ncS --arg request "$request_sha256" --arg launcher "$launcher_sha256" --arg executor "$executor_sha256" --argjson pid "$$" --arg sid "$sid" --arg pgid "$pgid" --arg token "$token" '{request_sha256:$request,launcher_sha256:$launcher,executor_sha256:$executor,pid:$pid,sid:$sid,pgid:$pgid,start_token:$token}'|atomic_new "$op/runner.started.json"; fi
   [[ -f "$op/runner.started.json" ]] || { journal "$op" REJECTED_PRE_APPLY runner_not_started; terminal "$op" REJECTED_PRE_APPLY runner_not_started; return 65; }
   runner_started_valid "$op/runner.started.json" && jq -e --arg req "$request_sha256" --arg launch "$launcher_sha256" --arg exec "$executor_sha256" '.request_sha256==$req and .launcher_sha256==$launch and .executor_sha256==$exec' "$op/runner.started.json" >/dev/null || { journal "$op" REJECTED_PRE_APPLY runner_not_started; terminal "$op" REJECTED_PRE_APPLY runner_not_started; return 65; }
 fi
 [[ $(sha "$op/candidate.rendered.json") == "$candidate_render_sha256" && $(sha "$op/rollback.rendered.json") == "$rollback_render_sha256" ]]||die 'sealed render drift' 65; j=$(live); jq -e --arg image "$rollback_image_id" '.Image==$image and .State.Running==true and .State.Status=="running" and (.State.Health.Status//"none")=="healthy" and .RestartCount==0' <<<"$j" >/dev/null||{ journal "$op" REJECTED_PRE_APPLY rollback_identity_mismatch; terminal "$op" REJECTED_PRE_APPLY rollback_identity_mismatch; return 65; }; seal_live_snapshot "$op" "$j"; snapshot_matches "$op" "$j"||die "snapshot identity mismatch" 65; seal_fleet_snapshot "$op"; fleet_matches "$op"||die 'peer fleet snapshot mismatch' 65
 auth="$r/authorizations/$operation_id.ready"; validate_auth "$auth"||{ journal "$op" REJECTED_PRE_APPLY authorization_invalid; terminal "$op" REJECTED_PRE_APPLY authorization_invalid; return 65; }; mv -T "$auth" "$r/authorizations/$operation_id.consumed"; sync "$r/authorizations"; journal "$op" APPLY_INTENT authorization_consumed; CURRENT_PHASE=mutated
 [[ -z ${HDDT_AFTER_APPLY_INTENT_HOOK:-} ]]||"$HDDT_AFTER_APPLY_INTENT_HOOK"; journal "$op" APPLYING candidate; apply_render "$op" candidate||{ rollback_live "$op" apply_failed; return 1; }; journal "$op" VERIFYING_BASE probes
 deadline=$(( $(now)+${HDDT_PROBE_SECONDS:-30} )); while ! fail=$(probe_once "$op" candidate); do attempts=$((attempts+1)); case $fail in exited|dead|unhealthy|third|restart_count|restart_or_identity|peer_drift|a2a) rollback_live "$op" "probe_$fail"; return 1;; health-8787|health-8644|health-8648|host-health-8644) if [[ $(now) -lt $deadline ]]; then journal "$op" VERIFYING_BASE "retry_$fail"; "${HDDT_SLEEP_BIN:-sleep}" "${HDDT_SLEEP_SECONDS:-1}"; continue; fi; rollback_live "$op" "probe_deadline_probe_$fail"; return 1;; created|absent) ;; esac; [[ $(now) -ge $deadline ]]&&{ rollback_live "$op" probe_deadline; return 1; }; journal "$op" VERIFYING_BASE "retry_$fail"; "${HDDT_SLEEP_BIN:-sleep}" "${HDDT_SLEEP_SECONDS:-1}"; done
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
 parse "$@"; reject_production_overrides; local r op state j class recoverable decision=none deadline
 r=$(root); classify_legacy "$r" "$operation_id"; init_root "$r"; op="$r/operations/$operation_id"; [[ -d $op ]]||die 'operation missing' 65; load_request "$op"
 exec 8>"$r/deploy.lock"; flock -xn 8||die 'lifecycle lock busy' 75
 exec 7>"$op/control.lock"; flock -x 7
 [[ -e $op/terminal.json ]]&&{ flock -u 7; return 0; }
 state=$(last_state "$op"); consume_decision_locked "$op"; decision=$decision_action
 if [[ $state == AWAITING_CONFIRMATION ]]; then deadline_valid "$op" 0||{ terminal_locked "$op" RECOVERY_UNRESOLVED deadline_invalid; flock -u 7; return 2; }; deadline=$(jq -r .confirmation_deadline_epoch "$op/deadline.json"); fi
 flock -u 7
 [[ -f $op/snapshot.json ]]&&jq -e --arg request "$request_sha256" '.request_sha256==$request and (.container_id|type=="string") and (.image_id|type=="string") and (.running|type=="boolean") and (.status|type=="string") and (.health|type=="string") and (.started_at|type=="string") and (.restart_count|type=="number")' "$op/snapshot.json" >/dev/null||{ journal "$op" RECOVERY_UNRESOLVED snapshot_invalid; terminal "$op" RECOVERY_UNRESOLVED snapshot_invalid; return 2; }
 j=$(live); class=$(candidate_relation "$op" "$j"); recoverable=$(candidate_recovery_relation "$op" "$j")
 case $state in
 PREPARED|AUTHORIZED|VALIDATING|SNAPSHOTTING) journal "$op" REJECTED_PRE_APPLY recover_preapply; terminal "$op" REJECTED_PRE_APPLY recover_preapply;;
 APPLY_INTENT) if [[ $(rollback_relation "$op" "$j") == rollback ]]; then journal "$op" REJECTED_PRE_APPLY no_mutation_after_intent; terminal "$op" REJECTED_PRE_APPLY no_mutation_after_intent; elif [[ $class == candidate ]]; then probe_once "$op" candidate >/dev/null&&{ journal "$op" SUCCEEDED recovered_candidate; terminal "$op" SUCCEEDED recovered_candidate; }||rollback_live "$op" recovery_probe_failed; elif [[ $recoverable == candidate ]]; then rollback_live "$op" recovery_restart_count; else journal "$op" RECOVERY_UNRESOLVED apply_intent_ambiguous; terminal "$op" RECOVERY_UNRESOLVED apply_intent_ambiguous; fi;;
 INTERRUPTED) if [[ $(rollback_relation "$op" "$j") == rollback ]]; then journal "$op" REJECTED_PRE_APPLY interrupted_before_apply; terminal "$op" REJECTED_PRE_APPLY interrupted_before_apply; elif [[ $class == candidate ]]&&probe_once "$op" candidate >/dev/null; then journal "$op" SUCCEEDED recovered_interrupted; terminal "$op" SUCCEEDED recovered_interrupted; elif [[ $recoverable == candidate ]]; then rollback_live "$op" recovery_restart_count; else journal "$op" RECOVERY_UNRESOLVED interrupted_ambiguous; terminal "$op" RECOVERY_UNRESOLVED interrupted_ambiguous; fi;;
 APPLYING|VERIFYING_BASE|CONFIRMING) if [[ $decision == rollback ]]; then rollback_live "$op" recovery_requested; elif [[ $decision == confirm && $class == candidate ]]&&probe_once "$op" candidate >/dev/null; then journal "$op" SUCCEEDED recovered_confirm; terminal "$op" SUCCEEDED recovered_confirm; elif [[ $class == candidate ]]&&probe_once "$op" candidate >/dev/null; then journal "$op" SUCCEEDED recovered_candidate; terminal "$op" SUCCEEDED recovered_candidate; elif [[ $recoverable == candidate ]]; then rollback_live "$op" recovery_probe_failed; elif [[ $(rollback_relation "$op" "$j") == rollback ]]; then journal "$op" ROLLED_BACK recovered_rollback; terminal "$op" ROLLED_BACK recovered_rollback; else journal "$op" RECOVERY_UNRESOLVED third_state; terminal "$op" RECOVERY_UNRESOLVED third_state; fi;;
 AWAITING_CONFIRMATION) if [[ $decision == confirm && $class == candidate ]]&&probe_once "$op" candidate >/dev/null; then journal "$op" SUCCEEDED recovered_confirm; terminal "$op" SUCCEEDED recovered_confirm; elif [[ $decision == rollback || $(now) -ge $deadline ]]; then rollback_live "$op" recovery_timeout_or_decision; elif [[ $recoverable == candidate && $class != candidate ]]; then rollback_live "$op" recovery_restart_count; else die 'confirmation window still active' 75; fi;;
 ROLLING_BACK) rollback_live "$op" recovery_continue;;
 *) journal "$op" RECOVERY_UNRESOLVED unknown_state; terminal "$op" RECOVERY_UNRESOLVED unknown_state;; esac
}
prune_command(){
 (($#==0))||die 'prune accepts no arguments' 64
 reject_production_overrides
 local r; r=$(root)
 [[ -d $r && ! -L $r ]]||die 'retention root unavailable' 65
 assert_safe_tree "$r"; assert_fixed_paths "$r"
 prune_expired "$r"
}
[[ ${1:-} != --help && ${1:-} != -h ]]||{ usage; exit 0; }; cmd=${1:-}; shift||true
case $cmd in prepare) prepare "$@";; run) run "$@";; confirm) control confirm "$@";; rollback) control rollback "$@";; recover) recover "$@";; prune) prune_command "$@";; *) usage; exit 64;; esac
