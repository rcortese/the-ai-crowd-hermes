#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT=$(realpath "${1:-ops/scripts/reapply-webui-v05228-ai-crowd-candidate.sh}")
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT; repo=$tmp/repo; mkdir -p "$repo"
git -C "$repo" init -q; git -C "$repo" config user.name test; git -C "$repo" config user.email test@example.invalid
printf 'base
' > "$repo/value.txt"; git -C "$repo" add value.txt; git -C "$repo" commit -qm base
target=$(git -C "$repo" rev-parse HEAD); target_tree=$(git -C "$repo" rev-parse HEAD^{tree}); printf 'patched
' > "$repo/value.txt"; printf 'new
' > "$repo/new.txt"
git -C "$repo" diff --binary > "$tmp/patch"; git -C "$repo" diff --no-index --binary /dev/null new.txt >> "$tmp/patch" || [[ $? == 1 ]]
git -C "$repo" reset --hard -q "$target"; rm -f "$repo/new.txt"; idx=$tmp/index; GIT_INDEX_FILE=$idx git -C "$repo" read-tree "$target"; GIT_INDEX_FILE=$idx git -C "$repo" apply --cached "$tmp/patch"; patched_tree=$(GIT_INDEX_FILE=$idx git -C "$repo" write-tree)
sha=$(sha256sum "$tmp/patch" | cut -d' ' -f1); bytes=$(stat -c %s "$tmp/patch")
python3 - "$tmp/manifest.json" "$target" "$target_tree" "$patched_tree" "$sha" "$bytes" <<'PYMANIFEST'
import json,pathlib,sys
path,target,target_tree,patched_tree,sha,size=sys.argv[1:]
pathlib.Path(path).write_text(json.dumps({"upstream_target_commit":target,"upstream_target_tree":target_tree,"patched_source_tree":patched_tree,"patch_sha256":sha,"patch_bytes":int(size),"patch_paths":["new.txt","value.txt"]}))
PYMANIFEST
"$SCRIPT" --repo "$repo" --patch "$tmp/patch" --manifest "$tmp/manifest.json"
[[ $(cat "$repo/value.txt") == patched && $(cat "$repo/new.txt") == new ]]
git -C "$repo" reset --hard -q "$target"; git -C "$repo" clean -fdq; printf 'dirty
' > "$repo/dirty.txt"; ! "$SCRIPT" --repo "$repo" --patch "$tmp/patch" --manifest "$tmp/manifest.json" 2>/dev/null; [[ -f "$repo/dirty.txt" ]]; rm "$repo/dirty.txt"
printf 'tamper
' >> "$tmp/patch"; ! "$SCRIPT" --repo "$repo" --patch "$tmp/patch" --manifest "$tmp/manifest.json" 2>/dev/null
[[ $(git -C "$repo" rev-parse HEAD) == "$target" && -z $(git -C "$repo" status --porcelain) ]]
printf 'reapply-runner-tests: PASS (exact apply, dirty fence, tamper rejection, rollback)
'
