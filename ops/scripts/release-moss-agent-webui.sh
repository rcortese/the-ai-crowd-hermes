#!/usr/bin/env bash
# One-shot, operator-authorized Moss Agent + WebUI release.
# Builds one immutable image, seals a rollback selector, upgrades the HDDT
# executor transactionally, then uses its verified rollback-capable cutover.
set -Eeuo pipefail
umask 077

STACK=/mnt/user/appdata/the-ai-crowd-candidates/update-20260916/the-ai-crowd-full-release
AGENT=/mnt/user/appdata/the-ai-crowd-candidates/update-20260916/hermes-agent-liveport-v2026.9.14
WEBUI=/mnt/user/appdata/the-ai-crowd-candidates/update-20260916/hermes-webui
NODE_INPUT=/mnt/user/appdata/the-ai-crowd/agents/private/moss/projects/clash-royale-war-bot
HDDT=/mnt/ssd/appdata/the-ai-crowd-hddt
EXPECTED_AGENT=12f3b6a9eeeb917268592e8a1e85eab7cb94c8cb
EXPECTED_WEBUI=64918590cdb4d5cc08e9968213a49389d0c6babd
LOCK=/mnt/ssd/appdata/the-ai-crowd-hddt/release-moss-agent-webui.lock

fail(){ printf 'RELEASE: %s\n' "$*" >&2; exit 65; }
[[ ${EUID:-$(id -u)} == 0 ]] || fail 'run as root on the Docker host'
for p in "$STACK" "$AGENT" "$WEBUI" "$NODE_INPUT" "$HDDT"; do [[ -d $p && ! -L $p ]] || fail "unsafe or missing directory: $p"; done
exec 9>"$LOCK"; flock -xn 9 || fail 'another release is active'

# Source identity is bound before any build or mutation.
[[ -z $(git -C "$STACK" status --porcelain) ]] || fail 'release checkout is dirty'
[[ -z $(git -C "$AGENT" status --porcelain) ]] || fail 'Agent candidate is dirty'
[[ -z $(git -C "$WEBUI" status --porcelain) ]] || fail 'WebUI candidate is dirty'
[[ $(git -C "$STACK" remote get-url origin) == git@github.com:rcortese/the-ai-crowd-hermes.git ]] || fail 'release checkout remote is not canonical'
[[ $(git -C "$AGENT" rev-parse HEAD) == "$EXPECTED_AGENT" ]] || fail 'unexpected Agent candidate revision'
[[ $(git -C "$WEBUI" rev-parse HEAD) == "$EXPECTED_WEBUI" ]] || fail 'unexpected WebUI candidate revision'
[[ -f $NODE_INPUT/package.json && -f $NODE_INPUT/package-lock.json && -d $NODE_INPUT/.playwright-browsers ]] || fail 'private Moss build input is incomplete'

# Source-only gates. They must complete before Docker receives any build input.
(
  cd "$AGENT"
  bash scripts/validate_all_candidates.sh
)
(
  cd "$STACK"
  bash ops/tests/run-moss-release-tests.sh
)

rollback=$(docker inspect the-ai-crowd-moss-1 --format '{{.Image}}')
[[ $rollback =~ ^sha256:[0-9a-f]{64}$ ]] || fail 'current Moss image is not an immutable image ID'
revision=$(git -C "$STACK" rev-parse HEAD)
tree=$(git -C "$STACK" rev-parse 'HEAD^{tree}')
base_revision=$(git -C "$STACK" rev-parse 'HEAD^')
candidate_suffix="${candidate#sha256:}"
tag="the-ai-crowd/moss-agent-webui:${revision:0:12}-${EXPECTED_AGENT:0:12}-${EXPECTED_WEBUI:0:12}"
export MOSS_BASE_IMAGE="$rollback"
export CLASH_ROYALE_BUILD_INPUT_DIR="$NODE_INPUT"
export HERMES_AGENT_SOURCE="$AGENT"
export HERMES_WEBUI_SOURCE="$WEBUI"
export HDDT_SOURCE_BASE_REVISION="$base_revision"
export BUILD_RECEIPT_ROOT="$HDDT/state/build-receipts"

"$STACK/ops/scripts/build-moss-all-in-one-candidate.sh" "$tag"
candidate=$(docker image inspect "$tag" --format '{{.Id}}')
[[ $candidate =~ ^sha256:[0-9a-f]{64}$ && $candidate != "$rollback" ]] || fail 'candidate image identity is invalid or unchanged'
receipt="$BUILD_RECEIPT_ROOT/sha256-${candidate#sha256:}.json"
[[ -f $receipt && ! -L $receipt ]] || fail 'candidate build receipt missing'
receipt_sha=$(sha256sum "$receipt" | cut -d' ' -f1)

# This performs a transactional installed-executor upgrade, retaining state and
# restoring bin/release-source if its post-install validation fails.
"$STACK/ops/scripts/bootstrap-hddt-moss-root.sh" \
  --source-worktree "$STACK" --source-revision "$revision" --source-tree "$tree" \
  --candidate-image-id "$candidate" --receipt "$receipt" --receipt-sha256 "$receipt_sha"

op="moss-agent-webui-$(date -u +%Y%m%d%H%M%S)-${candidate_suffix:0:12}"
"$HDDT/bin/hddt-moss.sh" prepare --operation-id "$op" --mode followable \
  --source-revision "$revision" --source-tree "$tree" \
  --canonical-remote git@github.com:rcortese/the-ai-crowd-hermes.git \
  --candidate-image-id "$candidate" --rollback-image-id "$rollback" --moss-base-image "$rollback" \
  --receipt-sha256 "$receipt_sha" --approval-context "operator-terminal:$op"
opdir="$HDDT/state/operations/$op"
request="$opdir/request.json"
request_sha=$(jq -er '.request_sha256|select(test("^[0-9a-f]{64}$"))' "$request")
expires=$(( $(date +%s) + 900 ))
jq -ncS --arg op "$op" --arg request "$request_sha" --arg candidate "$candidate" --arg rollback "$rollback" --arg base "$rollback" --arg rev "$revision" --arg tree "$tree" --arg cand "$(jq -r .candidate_render_sha256 "$request")" --arg roll "$(jq -r .rollback_render_sha256 "$request")" --arg builder "$(jq -r .builder_sha256 "$request")" --arg exec "$(jq -r .executor_sha256 "$request")" --arg launcher "$(jq -r .launcher_sha256 "$request")" --argjson now "$(date +%s)" --argjson expires "$expires" '{operation_id:$op,request_sha256:$request,candidate_image_id:$candidate,rollback_image_id:$rollback,moss_base_image:$base,source_revision:$rev,source_tree:$tree,source_remote:"git@github.com:rcortese/the-ai-crowd-hermes.git",candidate_render_sha256:$cand,rollback_render_sha256:$roll,builder_sha256:$builder,executor_sha256:$exec,launcher_sha256:$launcher,operations:["run"],consumed:false,approval_id:("operator-terminal-"+$op),approval_channel:"operator-terminal",approved_epoch:$now,expires_epoch:$expires}' >"$HDDT/state/authorizations/$op.ready"
chmod 600 "$HDDT/state/authorizations/$op.ready"

"$HDDT/bin/hddt-moss-launcher.sh" --operation-id "$op"
for _ in $(seq 1 300); do
  [[ -f $opdir/terminal.json ]] && fail "cutover stopped before confirmation: $(jq -r .state "$opdir/terminal.json")"
  [[ -f $opdir/journal.log && $(awk -F '\t' 'END{print $2}' "$opdir/journal.log") == AWAITING_CONFIRMATION ]] && break
  sleep 1
done
[[ -f $opdir/journal.log && $(awk -F '\t' 'END{print $2}' "$opdir/journal.log") == AWAITING_CONFIRMATION ]] || fail 'cutover did not reach its safe confirmation point'
"$HDDT/bin/hddt-moss.sh" confirm --operation-id "$op" --reason operator-terminal-automatic
for _ in $(seq 1 900); do [[ -f $opdir/terminal.json ]] && break; sleep 1; done
[[ -f $opdir/terminal.json ]] || fail 'no terminal cutover receipt'
jq -e --arg candidate "$candidate" '.state=="SUCCEEDED" and .candidate_image_id==$candidate' "$opdir/terminal.json" >/dev/null || { jq -cS '{state,reason,created_epoch}' "$opdir/terminal.json" >&2; exit 1; }
printf 'RELEASE_SUCCEEDED operation=%s candidate=%s rollback=%s receipt=%s\n' "$op" "$candidate" "$rollback" "$opdir/terminal.json"
