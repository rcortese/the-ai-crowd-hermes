#!/usr/bin/env bash
set -Eeuo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
bootstrap="$repo/ops/supervisor/moss-fence-bootstrap-supervisord.conf"
profile="$repo/ops/supervisor/moss-all-in-one-supervisord.conf"
bootstrap_dockerfile="$repo/ops/images/Dockerfile.moss-fence-bootstrap"
profile_dockerfile="$repo/ops/images/Dockerfile.moss-profile-migration"
for path in "$bootstrap" "$profile" "$bootstrap_dockerfile" "$profile_dockerfile"; do [[ -s $path && ! -L $path ]]; done
grep -Fxq 'command=/opt/hermes/.venv/bin/hermes gateway run' "$bootstrap"
! grep -Fq -- '-p moss gateway run' "$bootstrap"
! grep -Fq 'HERMES_AUTH_HOME' "$bootstrap"
! grep -Fq 'HERMES_PROFILE_COOKIE' "$bootstrap"
! grep -Fq 'HERMES_WEBUI_PROFILE_COOKIE_NAME' "$bootstrap"
grep -Fq 'HERMES_WEBUI_ADMISSION_FENCE="/opt/data/webui/admission-fence.json"' "$bootstrap"
grep -Fxq 'command=/opt/hermes/.venv/bin/hermes dashboard --host 127.0.0.1 --port 9119 --no-open --insecure' "$bootstrap"
grep -Fxq 'command=/opt/hermes/.venv/bin/hermes -p moss gateway run' "$profile"
grep -Fq 'HERMES_AUTH_HOME="/opt/data/provider-auth"' "$profile"
grep -Fq 'HERMES_WEBUI_PROFILE_COOKIE_NAME="hermes_profile_v2"' "$profile"
grep -Fq 'moss-fence-bootstrap-supervisord.conf' "$bootstrap_dockerfile"
grep -Fq 'moss-all-in-one-supervisord.conf' "$profile_dockerfile"
! cmp -s "$bootstrap" "$profile"
echo moss_profile_two_phase_contract_ok
