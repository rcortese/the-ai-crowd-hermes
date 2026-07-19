#!/usr/bin/env bash
# The live adapter is deliberately unavailable until Phase 7 provides a disposable
# WebUI fixture. Rehearsal accepts only a strict fake transcript, never a host URL.
set -Eeuo pipefail
[[ ${HDDT_REHEARSAL:-0} == 1 ]] || { printf '%s\n' 'native adapter requires isolated rehearsal' >&2; exit 77; }
[[ ${1:-} == --container && ${2:-} == the-ai-crowd-moss-1 && $# == 2 ]] || { printf '%s\n' 'native adapter received non-literal target' >&2; exit 64; }
[[ -n ${HDDT_NATIVE_TRANSCRIPT:-} && -f ${HDDT_NATIVE_TRANSCRIPT:-} && ! -L ${HDDT_NATIVE_TRANSCRIPT:-} ]] || { printf '%s\n' 'native adapter fixture unavailable' >&2; exit 78; }
# Transcript is a sanitised fake ordered-event projection: token/message, done, stream_end, cleanup.
mapfile -t events <"$HDDT_NATIVE_TRANSCRIPT"
[[ ${events[*]} == *'token'* && ${events[*]} == *'done'* && ${events[*]} == *'stream_end'* && ${events[*]} == *'cleanup=pass'* ]] || { printf '%s\n' 'native adapter transcript contract failed' >&2; exit 79; }
done_i=-1 end_i=-1
for i in "${!events[@]}"; do [[ ${events[$i]} == done ]] && done_i=$i; [[ ${events[$i]} == stream_end ]] && end_i=$i; done
(( done_i >= 0 && end_i > done_i )) || { printf '%s\n' 'native adapter terminal ordering failed' >&2; exit 79; }
printf '%s\n' 'NATIVE_CONVERSATION=PASS CLEANUP=PASS'
