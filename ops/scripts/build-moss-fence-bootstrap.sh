#!/usr/bin/env bash
set -Eeuo pipefail
usage() { printf '%s\n' 'usage: build-moss-fence-bootstrap.sh --output-dir ABSOLUTE_DIR --execute'; }
output_dir= execute=0
while (($#)); do
  case "$1" in
    --output-dir) (($# >= 2)) || { usage >&2; exit 64; }; output_dir=$2; shift 2 ;;
    --execute) execute=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done
[[ $output_dir == /* && -d $output_dir && ! -L $output_dir ]] || { usage >&2; exit 64; }
((execute)) || { printf '%s\n' 'refusing image build without --execute' >&2; exit 2; }
readonly live_base='sha256:af5e84f51db09af653f8989713c3f96d39caa5c602dc7c3f722993603addb43f'
readonly base_tag='the-ai-crowd/moss-all-in-one:fence-bootstrap-base-af5e84f51db09'
readonly repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
readonly source_sha=$(python3 - "$repo" <<'PY'
import hashlib,pathlib,sys
root=pathlib.Path(sys.argv[1]); h=hashlib.sha256()
for rel in ("ops/hermes-webui-overrides/apply-moss-profile-admission-fence.py","ops/images/Dockerfile.moss-fence-bootstrap","ops/supervisor/moss-fence-bootstrap-supervisord.conf"):
    h.update(rel.encode()+b"\0"); h.update((root/rel).read_bytes())
print(h.hexdigest())
PY
)
readonly tag="the-ai-crowd/moss-all-in-one:fence-bootstrap-${source_sha:0:16}"
readonly manifest="$output_dir/build-manifest.json"
[[ ! -e $manifest && ! -L $manifest ]] || { printf '%s\n' 'manifest already exists' >&2; exit 1; }
docker image inspect "$live_base" >/dev/null
cleanup_base_tag() { docker image rm "$base_tag" >/dev/null 2>&1 || true; }
trap cleanup_base_tag EXIT
if docker image inspect "$base_tag" >/dev/null 2>&1; then
  [[ $(docker image inspect --format '{{.Id}}' "$base_tag") == "$live_base" ]] || { printf '%s\n' 'temporary base tag collision' >&2; exit 1; }
else
  docker image tag "$live_base" "$base_tag"
fi
[[ $(docker image inspect --format '{{.Id}}' "$base_tag") == "$live_base" ]]
docker build --build-arg "LIVE_BASE_IMAGE=$base_tag" --file "$repo/ops/images/Dockerfile.moss-fence-bootstrap" --tag "$tag" "$repo"
image_id=$(docker image inspect --format '{{.Id}}' "$tag")
python3 - "$manifest" "$live_base" "$source_sha" "$tag" "$image_id" <<'PY'
import json,os,pathlib,sys,tempfile
path=pathlib.Path(sys.argv[1]); body={"schema":"moss-fence-bootstrap-build/v1","live_base_image_id":sys.argv[2],"source_contract_sha256":sys.argv[3],"candidate_tag":sys.argv[4],"candidate_image_id":sys.argv[5],"canonical_tag_mutated":False}
fd,tmp=tempfile.mkstemp(prefix=".build-manifest.",dir=path.parent)
try:
 with os.fdopen(fd,"w") as f: json.dump(body,f,indent=2,sort_keys=True); f.write("\n"); f.flush(); os.fsync(f.fileno())
 os.chmod(tmp,0o600); os.replace(tmp,path); dfd=os.open(path.parent,os.O_RDONLY|os.O_DIRECTORY); os.fsync(dfd); os.close(dfd)
finally:
 if os.path.exists(tmp): os.unlink(tmp)
PY
printf 'manifest=%s\nimage_id=%s\ntag=%s\n' "$manifest" "$image_id" "$tag"
