#!/usr/bin/env bash
# Operator-only entrypoint. Default check performs no production mutation.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
unset PYTHONPATH PYTHONHOME DOCKER_HOST DOCKER_CONTEXT GIT_DIR GIT_WORK_TREE CDPATH ENV BASH_ENV
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
MODE=${1:-check}
[[ $# -le 1 && $MODE =~ ^(check|apply|status|recover)$ ]] || { printf 'Uso: bash run-host.sh [check|apply|status|recover]\n' >&2; exit 64; }
[[ $EUID == 0 && $(hostname) == MEDIA ]] || { printf 'Execute como root@media.lan.\n' >&2; exit 77; }
if [[ $MODE == apply || $MODE == recover ]]; then
  printf 'Esta operação pode recriar os seis agentes, incluindo Moss/WebUI.\n'
  printf 'Feche tarefas ativas e não envie mensagens até a conclusão.\n'
  read -r -p 'Digite APLICAR para continuar: ' consent
  [[ $consent == APLICAR ]] || exit 1
  LOG=$(mktemp /var/log/the-ai-crowd-release-20260922.XXXXXX.log)
  nohup python3 -u "$ROOT/fleet_release.py" "$MODE" >"$LOG" 2>&1 </dev/null &
  printf 'Executor independente iniciado (PID %s). Log: %s\n' "$!" "$LOG"
  printf 'Consulte: bash %q status\n' "$ROOT/run-host.sh"
else
  exec python3 "$ROOT/fleet_release.py" "$MODE"
fi
