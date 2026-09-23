#!/usr/bin/env bash
# Visual companion; the hash-bound release executor remains unchanged.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
unset PYTHONPATH PYTHONHOME DOCKER_HOST DOCKER_CONTEXT GIT_DIR GIT_WORK_TREE CDPATH ENV BASH_ENV
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
exec python3 -u "$ROOT/run-visual.py" "${@}"
