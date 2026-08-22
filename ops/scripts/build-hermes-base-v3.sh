#!/usr/bin/env bash
# Controlled host executor. Source implementation alone does not authorize a build.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
LOCK="$ROOT/ops/manifests/hermes-base-v3.lock.json"
CONTRACT="$ROOT/ops/release/hermes_base_v3.py"
usage(){ echo "usage: $0 --final-tag REPOSITORY:TAG --receipt FILE" >&2; exit 64; }
final_tag= receipt=
while (($#)); do case "$1" in --final-tag) final_tag=${2:-}; shift 2;; --receipt) receipt=${2:-}; shift 2;; *) usage;; esac; done
[[ -n "$final_tag" && -n "$receipt" ]] || usage
command -v docker >/dev/null; command -v python3 >/dev/null; command -v git >/dev/null
python3 "$CONTRACT" validate-lock "$LOCK" >/dev/null
mapfile -t v < <(python3 -c 'import json,sys; x=json.load(open(sys.argv[1])); s=x["source"]; a=s["archive"]; i=x["image"]; print(s["git_dir"]); print(s["work_tree"]); print(s["commit"]); print(s["tree"]); print(a["sha256"]); print(a["bytes"]); print(i["repository"])' "$LOCK")
git_dir=${v[0]}; work_tree=${v[1]}; commit=${v[2]}; tree=${v[3]}; expected_sha=${v[4]}; expected_bytes=${v[5]}; repository=${v[6]}
[[ "$final_tag" == "$repository":* ]] || { echo "final tag must be under $repository" >&2; exit 64; }
pre_tag="$repository:pre-${commit:0:12}"; [[ "$final_tag" != "$pre_tag" ]] || { echo "final tag must differ" >&2; exit 64; }
[[ -z "$(git --git-dir="$git_dir" --work-tree="$work_tree" status --porcelain)" ]] || { echo "refusing dirty source worktree" >&2; exit 65; }
[[ "$(git --git-dir="$git_dir" rev-parse "$commit^{tree}")" == "$tree" ]] || { echo "source tree mismatch" >&2; exit 65; }
ctx=$(mktemp -d); trap 'rm -rf "$ctx"' EXIT
raw="$ctx/source.tar"; saved="$ctx/pre.tar"; normalized="$ctx/normalized.tar"
git --git-dir="$git_dir" --work-tree="$work_tree" archive --format=tar --prefix=hermes-agent/ "$commit" >"$raw"
[[ "$(sha256sum "$raw" | cut -d' ' -f1)" == "$expected_sha" && "$(wc -c <"$raw" | tr -d ' ')" == "$expected_bytes" ]] || { echo "archive binding mismatch" >&2; exit 65; }
mkdir "$ctx/context"; tar -xf "$raw" -C "$ctx/context" --no-same-owner
# Archive-only context, provenance labels, and no build network.
docker build --network=none --pull=false --tag "$pre_tag" --label "org.opencontainers.image.revision=$commit" --label "the-ai-crowd.source-commit=$commit" --label "the-ai-crowd.source-tree=$tree" --label "the-ai-crowd.source-archive-sha256=$expected_sha" "$ctx/context"
pre_id=$(docker image inspect "$pre_tag" --format '{{.Id}}')
docker image save "$pre_tag" -o "$saved"
python3 "$CONTRACT" normalize-image-tar "$saved" "$normalized" --final-tag "$final_tag"
docker image load -i "$normalized" >/dev/null
final_id=$(docker image inspect "$final_tag" --format '{{.Id}}'); [[ "$final_id" != "$pre_id" ]] || { echo "normalization did not create distinct final image" >&2; exit 65; }
# No network, read-only root, no bind mounts/volumes; only an ephemeral tmpfs.
docker run --rm --network=none --read-only --tmpfs /tmp:rw,noexec,nosuid,size=16m "$final_tag" hermes --help >/dev/null
python3 -c 'import hashlib,json,subprocess,sys; o,c,t,s,n,p,pi,f,fi=sys.argv[1:]; cfg=subprocess.check_output(["docker","image","inspect",f,"--format","{{json .Config}}"]); r={"schema":"the-ai-crowd.hermes-base-v3-receipt.v1","source_commit":c,"source_tree":t,"archive_sha256":s,"archive_bytes":int(n),"pre_normalization_tag":p,"pre_normalization_image_id":pi,"final_tag":f,"final_image_id":fi,"normalized_config_sha256":hashlib.sha256(cfg).hexdigest()}; open(o,"w").write(json.dumps(r,sort_keys=True,indent=2)+"\n")' "$receipt" "$commit" "$tree" "$expected_sha" "$expected_bytes" "$pre_tag" "$pre_id" "$final_tag" "$final_id"
python3 "$CONTRACT" verify-receipt "$LOCK" "$receipt"
printf 'hermes-base-v3: PASS final_tag=%s final_image_id=%s receipt=%s\n' "$final_tag" "$final_id" "$receipt"
