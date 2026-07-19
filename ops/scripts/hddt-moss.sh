#!/usr/bin/env bash
# Host Durable Deployment Transaction (HDDT), Moss v1.
set -Eeuo pipefail
umask 077
# EXIT trap is containment only; recovery never infers state from caller/PID.
trap ':' EXIT
readonly SERVICE=moss PROJECT=the-ai-crowd CONTAINER=the-ai-crowd-moss-1
# Lifecycle renders and applies use this selector only; tags are metadata, never authority.
readonly HDDT_IMAGE_SELECTOR=MOSS_IMAGE_REF
# State vocabulary is intentionally explicit: APPLY_INTENT, AWAITING_CONFIRMATION,
# REJECTED_PRE_APPLY, ROLLBACK_FAILED and RECOVERY_UNRESOLVED. Sealed inputs are
# candidate.rendered.json and rollback.rendered.json; future literal argv is
# compose up -d --no-build --no-deps --force-recreate moss.
readonly DEFAULT_ROOT=/mnt/user/appdata/the-ai-crowd-hddt
usage() { printf '%s\n' 'usage: hddt-moss.sh {prepare|run|confirm|rollback|recover} --operation-id ID [options]'; }
die() { printf 'HDDT: %s\n' "$*" >&2; exit "${2:-64}"; }
sha() { sha256sum "$1" | cut -d' ' -f1; }
valid_id() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{7,63}$ ]]; }
valid_image() { [[ "$1" =~ ^sha256:[0-9a-f]{64}$ ]]; }
atomic() { local out=$1; local tmp; tmp=$(mktemp "${out}.tmp.XXXXXX"); cat >"$tmp"; chmod 0600 "$tmp"; sync "$tmp"; ln "$tmp" "$out" 2>/dev/null || { rm -f "$tmp"; return 1; }; rm -f "$tmp"; sync "$(dirname "$out")"; }
state_root() {
  if [[ ${HDDT_REHEARSAL:-0} == 1 ]]; then printf '%s\n' "${HDDT_STATE_ROOT:?HDDT_STATE_ROOT required for rehearsal}"; return; fi
  printf '%s\n' "$DEFAULT_ROOT"
}
require_rehearsal_or_custody() {
  local root=$1
  if [[ ${HDDT_REHEARSAL:-0} != 1 ]]; then
    [[ $root == "$DEFAULT_ROOT" ]] || die 'production state-root override forbidden'
    [[ -d $root && $(stat -c %a "$root") == 700 && $(stat -c %u "$root") == 0 ]] || die 'production HDDT root is not approved' 65
    die 'production lifecycle requires an externally provisioned HDDT root and authorization' 77
  fi
  [[ $root != *'/the-ai-crowd/'* && $root != /mnt/user/appdata/the-ai-crowd* ]] || die 'state root overlaps live stack' 65
  mkdir -p "$root"/{operations,authorizations,build-receipts,outbox,staging}; chmod 700 "$root" "$root"/{operations,authorizations,build-receipts,outbox,staging}
}
append_state() { printf '%s %s %s\n' "$(date -u +%FT%TZ)" "$2" "$3" >>"$1/journal.log"; sync "$1/journal.log"; }
terminal() { local op=$1 state=$2 reason=$3; [[ ! -e $op/terminal.json ]] || return 0; printf '{"state":"%s","reason":"%s"}\n' "$state" "$reason" | atomic "$op/terminal.json"; : >"$(dirname "$(dirname "$op")")/outbox/$(basename "$op").ready"; chmod 0600 "$(dirname "$(dirname "$op")")/outbox/$(basename "$op").ready"; }
parse_common() { operation_id= mode= source_revision= source_tree= canonical_remote= candidate_image_id= rollback_image_id= moss_base_image= candidate_provenance_sha256= reason=; while (($#)); do case "$1" in --operation-id|--mode|--source-revision|--source-tree|--canonical-remote|--candidate-image-id|--rollback-image-id|--moss-base-image|--candidate-provenance-sha256|--reason) [[ $# -gt 1 ]] || die "missing value for $1"; case "$1" in --operation-id) operation_id=$2;; --mode) mode=$2;; --source-revision) source_revision=$2;; --source-tree) source_tree=$2;; --canonical-remote) canonical_remote=$2;; --candidate-image-id) candidate_image_id=$2;; --rollback-image-id) rollback_image_id=$2;; --moss-base-image) moss_base_image=$2;; --candidate-provenance-sha256) candidate_provenance_sha256=$2;; --reason) reason=$2;; esac; shift 2;; *) die "unknown argument: $1";; esac; done; valid_id "$operation_id" || die 'invalid operation-id'; }
prepare() {
  parse_common "$@"; [[ $mode == automatic || $mode == followable ]] || die 'invalid mode'; valid_image "$candidate_image_id" && valid_image "$rollback_image_id" && [[ $candidate_image_id != "$rollback_image_id" ]] || die 'invalid image IDs'; [[ $source_revision =~ ^[0-9a-f]{40}$ && $source_tree =~ ^[0-9a-f]{40}$ && $candidate_provenance_sha256 =~ ^[0-9a-f]{64}$ ]] || die 'invalid source/provenance'; [[ -n $canonical_remote && -n $moss_base_image && $moss_base_image != *[[:space:]]* ]] || die 'invalid source/base'; local root op; root=$(state_root); require_rehearsal_or_custody "$root"; op="$root/operations/$operation_id"; mkdir -p "$op/control"; chmod 700 "$op" "$op/control"; printf 'operation_id=%q\nmode=%q\nsource_revision=%q\nsource_tree=%q\ncandidate_image_id=%q\nrollback_image_id=%q\n' "$operation_id" "$mode" "$source_revision" "$source_tree" "$candidate_image_id" "$rollback_image_id" >"$op/request.env"; chmod 600 "$op/request.env"; sha "$op/request.env" >"$op/request.sha256"; append_state "$op" PREPARED prepared; printf '%s\n' "$(sha "$op/request.env")"
}
run() { parse_common "$@"; local root op; root=$(state_root); require_rehearsal_or_custody "$root"; op="$root/operations/$operation_id"; [[ -f $op/request.env && ! -e $op/terminal.json ]] || die 'operation missing or terminal' 65; [[ -f "$root/authorizations/$operation_id.ready" ]] || { append_state "$op" REJECTED_PRE_APPLY authorization_missing; terminal "$op" REJECTED_PRE_APPLY authorization_missing; return 65; }; mv "$root/authorizations/$operation_id.ready" "$root/authorizations/$operation_id.consumed"; append_state "$op" APPLY_INTENT authorization_consumed; append_state "$op" APPLYING rehearsal_only; append_state "$op" VERIFYING_BASE fake_green; terminal "$op" SUCCEEDED rehearsal_fake; }
control() { local action=$1; shift; parse_common "$@"; local root op; root=$(state_root); require_rehearsal_or_custody "$root"; op="$root/operations/$operation_id"; [[ -d $op && ! -e $op/terminal.json ]] || die 'operation missing or terminal' 65; ( flock -x 9; [[ ! -e $op/control/decision.request ]] || die 'decision already exists' 65; printf 'action=%s\nreason=%q\n' "$action" "$reason" | atomic "$op/control/decision.request"; ) 9>"$op/control.lock"; }
recover() { parse_common "$@"; local root op; root=$(state_root); require_rehearsal_or_custody "$root"; op="$root/operations/$operation_id"; [[ -d $op ]] || die 'operation missing' 65; [[ -e $op/terminal.json ]] && return 0; append_state "$op" RECOVERY_UNRESOLVED no_live_cas_in_rehearsal; terminal "$op" RECOVERY_UNRESOLVED no_live_cas_in_rehearsal; }
[[ ${1:-} != --help && ${1:-} != -h ]] || { usage; exit 0; }
cmd=${1:-}; shift || true
case "$cmd" in prepare) prepare "$@";; run) run "$@";; confirm) control confirm "$@";; rollback) control rollback "$@";; recover) recover "$@";; *) usage; exit 64;; esac
