#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd); installer=$root/ops/scripts/bootstrap-hddt-moss-root.sh
fail(){ printf 'bootstrap-test: RED %s\n' "$*" >&2; exit 1; }
fx=$(mktemp -d /tmp/hddt-bootstrap-test.XXXXXX); trap 'rm -rf -- "$fx"' EXIT
src=$fx/source; mkdir -p "$src/ops/scripts"
for p in hddt-moss.sh hddt-moss-launcher.sh hddt-moss-status.sh build-moss-all-in-one-candidate.sh; do printf '#!/usr/bin/env bash\nexit 0\n' >"$src/ops/scripts/$p"; chmod 755 "$src/ops/scripts/$p"; done
git init -q "$src"; git -C "$src" config user.email test@example.invalid; git -C "$src" config user.name test; git -C "$src" add .; git -C "$src" commit -qm fixture; git -C "$src" remote add origin git@github.com:rcortese/the-ai-crowd-hermes.git
rev=$(git -C "$src" rev-parse HEAD); tree=$(git -C "$src" rev-parse 'HEAD^{tree}'); image=sha256:b80f5a9a93faa6dea369b2c37648753110a3126eae24ff821065fe89e65628fb; receipt=$fx/receipt.json
jq -nc --arg r "$rev" --arg t "$tree" --arg i "$image" --arg e "$(sha256sum "$src/ops/scripts/hddt-moss.sh"|cut -d' ' -f1)" --arg l "$(sha256sum "$src/ops/scripts/hddt-moss-launcher.sh"|cut -d' ' -f1)" --arg b "$(sha256sum "$src/ops/scripts/build-moss-all-in-one-candidate.sh"|cut -d' ' -f1)" '{source_revision:$r,source_tree:$t,source_remote:"git@github.com:rcortese/the-ai-crowd-hermes.git",candidate_image_id:$i,executor_sha256:$e,launcher_sha256:$l,builder_sha256:$b}' >"$receipt"; rh=$(sha256sum "$receipt"|cut -d' ' -f1)
target=$fx/hddt-bootstrap-target/the-ai-crowd-hddt; mkdir -p "$(dirname "$target")"
run(){ HDDT_BOOTSTRAP_TEST=1 "$installer" --source-worktree "$src" --source-revision "$rev" --test-source-tree "$tree" --test-target "$target" --test-receipt "$receipt" --test-receipt-sha256 "$rh" "$@"; }
run
[[ $(stat -c '%u:%g:%a' "$target/bin/hddt-moss.sh") == 0:0:700 && $(stat -c '%u:%g:%a' "$target/state/build-receipts/sha256-${image#sha256:}.json") == 0:0:600 ]] || fail custody
git -C "$target/release-source" rev-parse --verify HEAD >/dev/null; [[ $(git -C "$target/release-source" remote get-url origin) == git@github.com:rcortese/the-ai-crowd-hermes.git ]] || fail remote
rm -rf -- "$target"; bad=${rh/a/b}; rc=0; run --test-receipt-sha256 "$bad" >/dev/null 2>&1 || rc=$?; [[ $rc != 0 && ! -e $target ]] || fail bad-receipt
ln -s /tmp "$target"; rc=0; run >/dev/null 2>&1 || rc=$?; [[ $rc != 0 && -L $target ]] || fail symlink; rm "$target"
printf '# changed\n' >>"$src/ops/scripts/hddt-moss.sh"; git -C "$src" add .; git -C "$src" commit -qm changed; rev=$(git -C "$src" rev-parse HEAD); tree=$(git -C "$src" rev-parse 'HEAD^{tree}'); rc=0; HDDT_BOOTSTRAP_TEST=1 "$installer" --source-worktree "$src" --source-revision "$rev" --test-source-tree "$tree" --test-target "$target" --test-receipt "$receipt" --test-receipt-sha256 "$rh" >/dev/null 2>&1 || rc=$?; [[ $rc != 0 && ! -e $target ]] || fail changed-script
if grep -Eq '\b(docker|compose)\b' "$installer"; then
 fail lifecycle-token
else
 rc=$?
 [[ $rc == 1 ]] || fail lifecycle-token-scan-error
fi
printf 'bootstrap-test: PASS happy=yes reds=3 no-docker-compose=yes\n'
