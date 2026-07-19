#!/usr/bin/env bash
# Host Durable Deployment Transaction (HDDT), Moss v1.
# This file never performs rehearsal behaviour unless HDDT_REHEARSAL=1 and all
# authority roots were explicitly redirected to a temporary fixture.
set -Eeuo pipefail
umask 077
readonly SERVICE=moss PROJECT=the-ai-crowd CONTAINER=the-ai-crowd-moss-1
readonly DEFAULT_ROOT=/mnt/user/appdata/the-ai-crowd-hddt
usage() { printf '%s\n' 'usage: hddt-moss.sh {prepare|run|confirm|rollback|recover} --operation-id ID [prepare fields]'; }
die() { printf 'HDDT: %s\n' "$1" >&2; exit "${2:-64}"; }
sha() { sha256sum "$1" | awk '{print $1}'; }
now() { if [[ -n ${HDDT_CLOCK:-} ]]; then "$HDDT_CLOCK"; else date -u +%s; fi; }
valid_id() { [[ $1 =~ ^[a-z0-9][a-z0-9-]{7,63}$ ]]; }
valid_image() { [[ $1 =~ ^sha256:[0-9a-f]{64}$ ]]; }
regular0600() { [[ -f $1 && ! -L $1 && $(stat -c %a "$1") == 600 ]]; }
write_atomic() { # destination, stdin; never overwrites
  local out=$1 tmp
  [[ ! -e $out ]] || return 17
  tmp=$(mktemp "${out}.tmp.XXXXXX")
  cat >"$tmp"; chmod 600 "$tmp"; sync "$tmp"
  ln "$tmp" "$out" 2>/dev/null || { rm -f "$tmp"; return 17; }
  rm -f "$tmp"; sync "$(dirname "$out")"
}
append_state() { printf '%s %s %s\n' "$(now)" "$2" "$3" >>"$1/journal.log"; sync "$1/journal.log"; }
root() { [[ ${HDDT_REHEARSAL:-0} == 1 ]] && printf '%s\n' "${HDDT_STATE_ROOT:?temporary HDDT_STATE_ROOT required}" || printf '%s\n' "$DEFAULT_ROOT"; }
stack_root() { [[ ${HDDT_REHEARSAL:-0} == 1 ]] && printf '%s\n' "${HDDT_STACK_ROOT:?temporary HDDT_STACK_ROOT required}" || printf '%s\n' /mnt/user/appdata/the-ai-crowd; }
docker_bin() { [[ ${HDDT_REHEARSAL:-0} == 1 ]] && printf '%s\n' "${HDDT_DOCKER_BIN:?fake HDDT_DOCKER_BIN required}" || printf '%s\n' /usr/bin/docker; }
require_custody() {
  local r=$1
  if [[ ${HDDT_REHEARSAL:-0} != 1 ]]; then
    [[ $r == "$DEFAULT_ROOT" && -d $r && $(stat -c %a "$r") == 700 && $(stat -c %u "$r") == 0 ]] || die 'production state root custody failed' 65
    die 'production execution is intentionally unavailable without external custody authorization' 77
  fi
  [[ $r == /tmp/* && $r != *'/the-ai-crowd'* ]] || die 'rehearsal root must be isolated under /tmp' 65
  mkdir -p "$r"/{operations,authorizations,build-receipts,outbox,staging}; chmod 700 "$r" "$r"/{operations,authorizations,build-receipts,outbox,staging}
}
terminal() {
  local op=$1 state=$2 reason=$3 r; r=$(dirname "$(dirname "$op")")
  [[ ! -e $op/terminal.json ]] || return 0
  printf '{"state":"%s","reason":"%s"}\n' "$state" "$reason" | write_atomic "$op/terminal.json" || return 0
  : | write_atomic "$r/outbox/$(basename "$op").ready"
}
parse() {
  operation_id= mode= source_revision= source_tree= canonical_remote= candidate_image_id= rollback_image_id= moss_base_image= candidate_provenance_sha256= reason= confirmation_seconds=${HDDT_CONFIRMATION_SECONDS:-600}
  while (($#)); do case "$1" in
    --operation-id|--mode|--source-revision|--source-tree|--canonical-remote|--candidate-image-id|--rollback-image-id|--moss-base-image|--candidate-provenance-sha256|--reason|--confirmation-seconds)
      (($# >= 2)) || die "missing value for $1"; case $1 in
        --operation-id) operation_id=$2;; --mode) mode=$2;; --source-revision) source_revision=$2;; --source-tree) source_tree=$2;; --canonical-remote) canonical_remote=$2;; --candidate-image-id) candidate_image_id=$2;; --rollback-image-id) rollback_image_id=$2;; --moss-base-image) moss_base_image=$2;; --candidate-provenance-sha256) candidate_provenance_sha256=$2;; --reason) reason=$2;; --confirmation-seconds) confirmation_seconds=$2;; esac; shift 2;;
    *) die "unknown argument: $1";; esac; done
  valid_id "$operation_id" || die 'invalid operation-id'
}
load_request() { # safe fixed parser, never eval/source arbitrary input
  local op=$1 k v; while IFS== read -r k v; do case $k in operation_id|mode|source_revision|source_tree|canonical_remote|candidate_image_id|rollback_image_id|moss_base_image|candidate_provenance_sha256|request_sha256|confirmation_deadline_epoch) printf -v "$k" '%s' "$v";; *) die 'invalid request key' 65;; esac; done <"$op/request.env";
}
copy_input() { local src=$1 dst=$2; [[ -f $src && ! -L $src ]] || die "unsafe compose input: $src" 65; mkdir -p "$(dirname "$dst")"; cp -- "$src" "$dst"; chmod 600 "$dst"; }
check_provenance() {
  local r=$1 receipt="$r/build-receipts/sha256-${candidate_image_id#sha256:}.json"
  regular0600 "$receipt" || die 'build receipt missing or unsafe' 65
  [[ $(sha "$receipt") == "$candidate_provenance_sha256" ]] || die 'build receipt hash mismatch' 65
  grep -Fq "\"source_revision\":\"$source_revision\"" "$receipt" && grep -Fq "\"source_tree\":\"$source_tree\"" "$receipt" && grep -Fq "\"candidate_image_id\":\"$candidate_image_id\"" "$receipt" && grep -Fq "\"base_image\":\"$moss_base_image\"" "$receipt" || die 'build receipt schema/binding mismatch' 65
}
render() { # op, candidate|rollback, image
  local op=$1 kind=$2 image=$3 sr db out; sr=$(stack_root); db=$(docker_bin); out="$op/$kind.rendered.json"
  env -i HOME=/root PATH="$PATH" MOSS_BASE_IMAGE="$moss_base_image" MOSS_IMAGE_REF="$image" "$db" compose --env-file "$op/compose-inputs/.env" --project-directory "$sr" --project-name "$PROJECT" -f "$op/compose-inputs/compose.yaml" config --format json >"$out.tmp"
  grep -Fq "\"image\":\"$image\"" "$out.tmp" || die "sealed $kind render image mismatch" 65
  grep -Eq 'env_file|\$\{' "$out.tmp" && die "sealed $kind render unresolved" 65
  chmod 600 "$out.tmp"; sync "$out.tmp"; mv "$out.tmp" "$out"; sync "$op"; printf '%s\n' "$(sha "$out")" >"$op/$kind.rendered.sha256"
}
prepare() {
  parse "$@"; [[ $mode == automatic || $mode == followable ]] || die 'invalid mode'; valid_image "$candidate_image_id" && valid_image "$rollback_image_id" && [[ $candidate_image_id != "$rollback_image_id" ]] || die 'invalid image IDs'
  [[ $source_revision =~ ^[0-9a-f]{40}$ && $source_tree =~ ^[0-9a-f]{40}$ && $candidate_provenance_sha256 =~ ^[0-9a-f]{64}$ && -n $canonical_remote && $moss_base_image != *[[:space:]]* ]] || die 'invalid source/provenance/base'
  local r op stage sr request_hash; r=$(root); require_custody "$r"; op="$r/operations/$operation_id"; sr=$(stack_root)
  exec 9>"$r/prepare.lock"; flock -x 9
  request_hash=$(printf 'operation_id=%s\nmode=%s\nsource_revision=%s\nsource_tree=%s\ncanonical_remote=%s\ncandidate_image_id=%s\nrollback_image_id=%s\nmoss_base_image=%s\ncandidate_provenance_sha256=%s\n' "$operation_id" "$mode" "$source_revision" "$source_tree" "$canonical_remote" "$candidate_image_id" "$rollback_image_id" "$moss_base_image" "$candidate_provenance_sha256" | sha256sum | awk '{print $1}')
  if [[ -d $op ]]; then [[ -f $op/request.sha256 && $(<"$op/request.sha256") == "$request_hash" ]] || die 'operation-id payload diverges' 65; printf '%s\n' "$request_hash"; return; fi
  stage=$(mktemp -d "$r/staging/$operation_id.XXXXXX"); chmod 700 "$stage"; mkdir -p "$stage/compose-inputs/env" "$stage/control"; chmod 700 "$stage/control"
  printf 'operation_id=%s\nmode=%s\nsource_revision=%s\nsource_tree=%s\ncanonical_remote=%s\ncandidate_image_id=%s\nrollback_image_id=%s\nmoss_base_image=%s\ncandidate_provenance_sha256=%s\nrequest_sha256=%s\nconfirmation_deadline_epoch=%s\n' "$operation_id" "$mode" "$source_revision" "$source_tree" "$canonical_remote" "$candidate_image_id" "$rollback_image_id" "$moss_base_image" "$candidate_provenance_sha256" "$request_hash" "$(( $(now) + confirmation_seconds ))" >"$stage/request.env"; chmod 600 "$stage/request.env"; printf '%s\n' "$request_hash" >"$stage/request.sha256"; chmod 600 "$stage/request.sha256"
  check_provenance "$r"; cp "$r/build-receipts/sha256-${candidate_image_id#sha256:}.json" "$stage/candidate-provenance.json"; chmod 600 "$stage/candidate-provenance.json"
  copy_input "$sr/compose.yaml" "$stage/compose-inputs/compose.yaml"; copy_input "$sr/.env" "$stage/compose-inputs/.env"; copy_input "$sr/env/fleet.env" "$stage/compose-inputs/env/fleet.env"; copy_input "$sr/env/moss-webui.env" "$stage/compose-inputs/env/moss-webui.env"
  load_request "$stage"; render "$stage" candidate "$candidate_image_id"; render "$stage" rollback "$rollback_image_id"
  printf 'rollback_image_id=%s\ncandidate_image_id=%s\nsource_revision=%s\nsource_tree=%s\nrequest_sha256=%s\ncandidate_render_sha256=%s\nrollback_render_sha256=%s\n' "$rollback_image_id" "$candidate_image_id" "$source_revision" "$source_tree" "$request_sha256" "$(<"$stage/candidate.rendered.sha256")" "$(<"$stage/rollback.rendered.sha256")" >"$stage/snapshot.env"; chmod 600 "$stage/snapshot.env"; : >"$stage/journal.log"; chmod 600 "$stage/journal.log"; append_state "$stage" PREPARED prepared
  mv "$stage" "$op"; sync "$r/operations"; printf '%s\n' "$request_hash"
}
validate_auth() { # authorization is external JSON, strictly bound to request and expiry
  local file=$1; regular0600 "$file" || return 1
  grep -Fq "\"operation_id\":\"$operation_id\"" "$file" && grep -Fq "\"request_sha256\":\"$request_sha256\"" "$file" && grep -Fq "\"candidate_image_id\":\"$candidate_image_id\"" "$file" && grep -Fq '"operations":["run"]' "$file" || return 1
  local expiry; expiry=$(sed -n 's/.*"expires_epoch":\([0-9][0-9]*\).*/\1/p' "$file"); [[ $expiry =~ ^[0-9]+$ && $expiry -ge $(now) ]]
}
apply_render() { local op=$1 kind=$2 db; db=$(docker_bin); env -i HOME=/root PATH="$PATH" "$db" compose --project-directory "$(stack_root)" --project-name "$PROJECT" -f "$op/$kind.rendered.json" up -d --no-build --no-deps --force-recreate "$SERVICE"; }
verify_base() { local db; db=$(docker_bin); "$db" inspect "$CONTAINER" | grep -Fq "\"image\":\"$candidate_image_id\"" || return 1; "$db" inspect "$CONTAINER" | grep -Fq '"health":"healthy"' || return 1; "$db" exec "$CONTAINER" health-8787 && "$db" exec "$CONTAINER" health-8644 && "$db" exec "$CONTAINER" health-8648 && "$db" host-health-8644; }
rollback_live() { local op=$1 why=$2; append_state "$op" ROLLING_BACK "$why"; if apply_render "$op" rollback && "$(docker_bin)" inspect "$CONTAINER" | grep -Fq "\"image\":\"$rollback_image_id\""; then append_state "$op" ROLLED_BACK "$why"; terminal "$op" ROLLED_BACK "$why"; else append_state "$op" ROLLBACK_FAILED "$why"; terminal "$op" ROLLBACK_FAILED "$why"; fi; }
run() {
  parse "$@"; local r op auth; r=$(root); require_custody "$r"; op="$r/operations/$operation_id"; [[ -d $op && ! -e $op/terminal.json ]] || die 'operation missing or terminal' 65; load_request "$op"; auth="$r/authorizations/$operation_id.ready"
  exec 8>"$r/deploy.lock"; flock -x 8
  if ! "$(docker_bin)" inspect "$CONTAINER" | grep -Fq "\"image\":\"$rollback_image_id\""; then append_state "$op" REJECTED_PRE_APPLY rollback_identity_mismatch; terminal "$op" REJECTED_PRE_APPLY rollback_identity_mismatch; return 65; fi
  if ! validate_auth "$auth"; then append_state "$op" REJECTED_PRE_APPLY authorization_invalid; terminal "$op" REJECTED_PRE_APPLY authorization_invalid; return 65; fi
  mv "$auth" "$r/authorizations/$operation_id.consumed"; sync "$r/authorizations"; append_state "$op" APPLY_INTENT authorization_consumed
  append_state "$op" APPLYING candidate; if ! apply_render "$op" candidate; then rollback_live "$op" apply_failed; return 1; fi
  append_state "$op" VERIFYING_BASE probes; local deadline=$(( $(now) + ${HDDT_PROBE_SECONDS:-9} )); while ! verify_base; do [[ $(now) -ge $deadline ]] && { rollback_live "$op" probe_deadline; return 1; }; sleep "${HDDT_SLEEP_SECONDS:-1}"; done
  if [[ $mode == automatic ]]; then append_state "$op" VERIFYING_AUTOMATIC native; HDDT_REHEARSAL=1 "$HDDT_NATIVE_ADAPTER" --container "$CONTAINER" || { rollback_live "$op" native_failed; return 1; }; append_state "$op" SUCCEEDED automatic; terminal "$op" SUCCEEDED automatic; return; fi
  append_state "$op" AWAITING_CONFIRMATION awaiting; while :; do
    if [[ -e $op/control/decision.request ]]; then grep -Fq 'action=confirm' "$op/control/decision.request" && { verify_base && { append_state "$op" SUCCEEDED confirmed; terminal "$op" SUCCEEDED confirmed; return; }; rollback_live "$op" confirm_readback_failed; return; }; rollback_live "$op" requested; return; fi
    [[ $(now) -ge $confirmation_deadline_epoch ]] && { rollback_live "$op" confirmation_timeout; return; }; sleep "${HDDT_SLEEP_SECONDS:-1}"
  done
}
control() { local action=$1; shift; parse "$@"; local r op; r=$(root); require_custody "$r"; op="$r/operations/$operation_id"; [[ -d $op && ! -e $op/terminal.json ]] || die 'operation missing or terminal' 65; exec 7>"$op/control.lock"; flock -x 7; [[ ! -e $op/control/decision.request ]] || die 'decision already exists' 65; printf 'action=%s\nreason=%s\n' "$action" "${reason:-operator}" | write_atomic "$op/control/decision.request"; }
recover() {
  parse "$@"; local r op last; r=$(root); require_custody "$r"; op="$r/operations/$operation_id"; [[ -d $op ]] || die 'operation missing' 65; [[ -e $op/terminal.json ]] && return 0; load_request "$op"; last=$(awk 'END{print $2}' "$op/journal.log")
  case $last in PREPARED|VALIDATING|SNAPSHOTTING) append_state "$op" REJECTED_PRE_APPLY recover_pre_apply; terminal "$op" REJECTED_PRE_APPLY recover_pre_apply;; APPLY_INTENT|APPLYING|VERIFYING_BASE|VERIFYING_AUTOMATIC|CONFIRMING|AWAITING_CONFIRMATION) if "$(docker_bin)" inspect "$CONTAINER" | grep -Fq "\"image\":\"$candidate_image_id\""; then [[ -e $op/control/decision.request ]] && grep -Fq 'action=rollback' "$op/control/decision.request" && rollback_live "$op" recovery_requested || { verify_base && { append_state "$op" SUCCEEDED recovered; terminal "$op" SUCCEEDED recovered; } || rollback_live "$op" recovery_verify_failed; }; elif "$(docker_bin)" inspect "$CONTAINER" | grep -Fq "\"image\":\"$rollback_image_id\""; then append_state "$op" ROLLED_BACK recovered_rollback; terminal "$op" ROLLED_BACK recovered_rollback; else append_state "$op" RECOVERY_UNRESOLVED third_state; terminal "$op" RECOVERY_UNRESOLVED third_state; fi;; *) append_state "$op" RECOVERY_UNRESOLVED unknown_state; terminal "$op" RECOVERY_UNRESOLVED unknown_state;; esac
}
trap 'rc=$?; exit $rc' EXIT
[[ ${1:-} != --help && ${1:-} != -h ]] || { usage; exit 0; }
cmd=${1:-}; shift || true
case $cmd in prepare) prepare "$@";; run) run "$@";; confirm) control confirm "$@";; rollback) control rollback "$@";; recover) recover "$@";; *) usage; exit 64;; esac
