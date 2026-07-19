#!/usr/bin/env bash
# HDDT automatic adapter. Real invocation is intentionally unavailable until a disposable WebUI fixture is provided.
set -Eeuo pipefail
[[ ${HDDT_REHEARSAL:-0} == 1 ]] || { echo 'native adapter requires isolated rehearsal' >&2; exit 77; }
[[ ${HDDT_NATIVE_FAKE_PASS:-0} == 1 ]] || { echo 'native adapter fixture unavailable' >&2; exit 78; }
printf '%s\n' 'NATIVE_CONVERSATION=PASS CLEANUP=PASS'
