#!/usr/bin/env bash
set -Eeuo pipefail
usage(){ echo "usage: $0 --repo PATH --patch PATH --manifest PATH" >&2; exit 64; }
repo= patch= manifest=
while (($#)); do case "$1" in --repo) [[ $# -ge 2 ]] || usage; repo=$2; shift 2;; --patch) [[ $# -ge 2 ]] || usage; patch=$2; shift 2;; --manifest) [[ $# -ge 2 ]] || usage; manifest=$2; shift 2;; *) usage;; esac; done
[[ -n "$repo" && -n "$patch" && -n "$manifest" ]] || usage
[[ -d "$repo/.git" && -f "$patch" && -f "$manifest" ]] || { echo "ERROR: missing repo, patch, or manifest" >&2; exit 66; }
readarray -t meta < <(python3 - "$manifest" "$patch" <<'PYMETA'
import hashlib,json,pathlib,sys
m=json.loads(pathlib.Path(sys.argv[1]).read_text()); p=pathlib.Path(sys.argv[2]).read_bytes()
assert hashlib.sha256(p).hexdigest()==m["patch_sha256"], "patch sha256 mismatch"
assert len(p)==m["patch_bytes"], "patch byte count mismatch"
print(m["upstream_target_commit"]); print(m["upstream_target_tree"]); print(m["patched_source_tree"])
for path in m["patch_paths"]: print("PATH="+path)
PYMETA
)
target=${meta[0]}; target_tree=${meta[1]}; expected_tree=${meta[2]}; expected_paths=(); for item in "${meta[@]:3}"; do expected_paths+=("${item#PATH=}"); done
[[ "$target" =~ ^[0-9a-f]{40}$ && "$target_tree" =~ ^[0-9a-f]{40}$ && "$expected_tree" =~ ^[0-9a-f]{40}$ ]] || { echo "ERROR: invalid immutable manifest identity" >&2; exit 65; }
[[ $(git -C "$repo" rev-parse HEAD) == "$target" ]] || { echo "ERROR: target commit mismatch" >&2; exit 65; }
[[ $(git -C "$repo" rev-parse HEAD^{tree}) == "$target_tree" ]] || { echo "ERROR: target tree mismatch" >&2; exit 65; }
[[ -z $(git -C "$repo" status --porcelain) ]] || { echo "ERROR: target worktree must be clean" >&2; exit 65; }
rollback(){ git -C "$repo" reset --hard "$target" >/dev/null; git -C "$repo" clean -fd >/dev/null; }
trap 'rc=$?; rollback; exit $rc' ERR INT TERM
git -C "$repo" apply --check "$patch"; git -C "$repo" apply "$patch"
mapfile -t actual_paths < <({ git -C "$repo" diff --name-only "$target"; git -C "$repo" ls-files --others --exclude-standard; } | LC_ALL=C sort -u)
mapfile -t expected_sorted < <(printf '%s
' "${expected_paths[@]}" | LC_ALL=C sort -u)
[[ "${actual_paths[*]}" == "${expected_sorted[*]}" ]] || { printf 'ERROR: changed path mismatch
expected=%s
actual=%s
' "${expected_sorted[*]}" "${actual_paths[*]}" >&2; false; }
idx=$(mktemp); rm -f "$idx"; GIT_INDEX_FILE=$idx git -C "$repo" read-tree "$target"; GIT_INDEX_FILE=$idx git -C "$repo" add -- "${actual_paths[@]}"; actual_tree=$(GIT_INDEX_FILE=$idx git -C "$repo" write-tree); rm -f "$idx"
[[ "$actual_tree" == "$expected_tree" ]] || { echo "ERROR: patched tree mismatch" >&2; false; }
trap - ERR INT TERM
printf 'PATCH_APPLIED target=%s tree=%s patch_sha256=%s
' "$target" "$actual_tree" "$(sha256sum "$patch" | cut -d' ' -f1)"
