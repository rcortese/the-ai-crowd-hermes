#!/usr/bin/env bash
# Host-only launcher; start via SSH on MEDIA, not via docker exec.
set -euo pipefail
[[ "${1:-}" == 'approved-launch' ]] || exit 2
HERE="$(cd "$(dirname "$0")" && pwd -P)"
[[ "$(hostname -s)" == MEDIA ]] || { printf 'wrong host\n' >&2; exit 3; }
[[ -x /usr/bin/setsid && -x /usr/bin/nohup && -x /usr/bin/flock ]] || exit 4
[[ ! -e "$HERE/launcher.pid" ]] || { printf 'existing launcher receipt requires reconciliation\n' >&2; exit 5; }
python3 "$HERE/preflight.py"
printf 'LAUNCHING\n' > "$HERE/launcher.state"
/usr/bin/setsid /usr/bin/nohup bash "$HERE/supervise.sh" approved-supervise > "$HERE/activation.log" 2>&1 < /dev/null &
pid=$!
printf '%s\n' "$pid" > "$HERE/launcher.pid"
sleep 1
if kill -0 "$pid" 2>/dev/null; then
  printf 'DETACHED pid=%s\n' "$pid" > "$HERE/launcher.state"
else
  printf 'EXITED_EARLY pid=%s\n' "$pid" > "$HERE/launcher.state"
fi
printf 'host_launcher_pid=%s; inspect launcher.state, activation.state, and Docker after this request exits\n' "$pid"
