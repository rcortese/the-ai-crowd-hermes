#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/ops/scripts/build-moss-integrated-release.sh"
DOCKERFILE="$ROOT/ops/images/Dockerfile.moss-integrated-release"
bash -n "$SCRIPT"
grep -Fq -- '--pull=false' "$SCRIPT"
grep -Fq -- '--build-context "agent_source=' "$SCRIPT"
grep -Fq -- '--build-context "webui_source=' "$SCRIPT"
grep -Fq 'production_lifecycle":False' "$SCRIPT"
grep -Fq 'docker image tag "$BASE_IMAGE" "$BASE_ALIAS"' "$SCRIPT"
grep -Fq 'temporary base alias identity mismatch' "$SCRIPT"
grep -Fq 'trap cleanup EXIT' "$SCRIPT"
grep -Fq 'org.the-ai-crowd.hermes-agent-revision' "$DOCKERFILE"
grep -Fq 'org.the-ai-crowd.hermes-webui-revision' "$DOCKERFILE"
grep -Fq 'org.the-ai-crowd.moss-source-revision' "$DOCKERFILE"
set +e
out=$("$SCRIPT" 2>&1)
rc=$?
set -e
[[ $rc -eq 64 ]]
[[ $out == usage:* ]]
printf '%s\n' 'test-build-moss-integrated-release: PASS'
