#!/usr/bin/env bash
set -Eeuo pipefail
usage() { printf '%s\n' 'usage: build-moss-profile-candidate.sh --output-dir ABSOLUTE_DIR --execute'; }
output_dir= execute=0
while (($#)); do
  case "$1" in
    --output-dir) (($# > 1)) || { usage >&2; exit 64; }; output_dir=$2; shift 2 ;;
    --execute) execute=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done
[[ $output_dir == /* && -d $output_dir && ! -L $output_dir ]] || { usage >&2; exit 64; }
((execute)) || { printf '%s\n' 'refusing image build without --execute' >&2; exit 2; }
readonly live_base='sha256:af5e84f51db09af653f8989713c3f96d39caa5c602dc7c3f722993603addb43f'
readonly base_tag='the-ai-crowd/moss-all-in-one:profile-migration-base-af5e84f51db09'
readonly repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
readonly source_sha=$(python3 - "$repo" <<'PY'
import hashlib, pathlib, sys
root=pathlib.Path(sys.argv[1]); h=hashlib.sha256()
for rel in (
    "ops/images/Dockerfile.moss-profile-migration",
    "ops/hermes-webui-overrides/apply-moss-profile-admission-fence.py",
    "ops/supervisor/moss-all-in-one-supervisord.conf",
):
    h.update(rel.encode()+b"\0")
    h.update((root/rel).read_bytes())
print(h.hexdigest())
PY
)
readonly tag="the-ai-crowd/moss-all-in-one:profile-migration-${source_sha:0:16}"
readonly manifest="$output_dir/build-manifest.json"
[[ ! -e $manifest && ! -L $manifest ]] || { printf '%s\n' 'manifest already exists' >&2; exit 1; }
docker image inspect "$live_base" >/dev/null
cleanup_base_tag() { docker image rm "$base_tag" >/dev/null 2>&1 || true; }
trap cleanup_base_tag EXIT
if docker image inspect "$base_tag" >/dev/null 2>&1; then
  [[ $(docker image inspect --format '{{.Id}}' "$base_tag") == "$live_base" ]] || {
    printf '%s\n' 'temporary base tag collision' >&2
    exit 1
  }
else
  docker image tag "$live_base" "$base_tag"
fi
[[ $(docker image inspect --format '{{.Id}}' "$base_tag") == "$live_base" ]]
docker build \
  --build-arg "LIVE_BASE_IMAGE=$base_tag" \
  --file "$repo/ops/images/Dockerfile.moss-profile-migration" \
  --tag "$tag" \
  "$repo"
image_id=$(docker image inspect --format '{{.Id}}' "$tag")
[[ $image_id == sha256:* ]]
tmp="$output_dir/.build-manifest.$$.tmp"
python3 - "$tmp" "$live_base" "$tag" "$image_id" "$source_sha" <<'PY'
import json, os, pathlib, sys
out, base, tag, image, source = sys.argv[1:]
payload = {
    "schema": "moss-profile-candidate-build/v1",
    "live_base_image_id": base,
    "candidate_tag": tag,
    "candidate_image_id": image,
    "source_contract_sha256": source,
    "canonical_tag_mutated": False,
}
p = pathlib.Path(out)
p.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
os.chmod(p, 0o600)
with p.open("rb") as fh: os.fsync(fh.fileno())
PY
mv "$tmp" "$manifest"
python3 - "$output_dir" <<'PY'
import os, pathlib, sys
fd=os.open(sys.argv[1], os.O_RDONLY|os.O_DIRECTORY)
os.fsync(fd); os.close(fd)
PY
printf 'manifest=%s\nimage_id=%s\ntag=%s\n' "$manifest" "$image_id" "$tag"
