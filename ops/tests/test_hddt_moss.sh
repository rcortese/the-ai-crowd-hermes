#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
script="$root/ops/scripts/hddt-moss.sh"
[[ -x "$script" ]] || { echo 'missing HDDT executor' >&2; exit 1; }
help=$("$script" --help)
[[ "$help" == *'prepare'* && "$help" == *'recover'* ]] || { echo 'HDDT CLI contract missing' >&2; exit 1; }
for needle in \
  'HDDT_REHEARSAL' 'MOSS_IMAGE_REF' 'APPLY_INTENT' 'REJECTED_PRE_APPLY' \
  'RECOVERY_UNRESOLVED' 'AWAITING_CONFIRMATION' 'candidate.rendered.json' \
  'rollback.rendered.json' '--no-build --no-deps --force-recreate' \
  'authorizations' 'control/decision.request'; do
  grep -Fq -- "$needle" "$script" || { echo "missing contract: $needle" >&2; exit 1; }
done
if "$script" prepare --operation-id ../bad --mode automatic 2>/dev/null; then
  echo 'invalid operation ID accepted' >&2; exit 1
fi
echo 'hddt-foundation-contract: PASS'
