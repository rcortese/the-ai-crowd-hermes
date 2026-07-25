#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd); installer=$root/ops/scripts/bootstrap-hddt-moss-root.sh
fail(){ printf 'bootstrap-test: RED %s\n' "$*" >&2; exit 1; }
fx=$(mktemp -d /tmp/hddt-bootstrap-test.XXXXXX); trap 'rm -rf -- "$fx"' EXIT
src=$fx/source; mkdir -p "$src/ops/scripts"
for p in hddt-moss.sh hddt-moss-launcher.sh hddt-moss-status.sh build-moss-all-in-one-candidate.sh; do printf '#!/usr/bin/env bash\n# %s\nexit 0\n' "$p" >"$src/ops/scripts/$p"; chmod 755 "$src/ops/scripts/$p"; done
git init -q "$src"; git -C "$src" config user.email test@example.invalid; git -C "$src" config user.name test; git -C "$src" add .; git -C "$src" commit -qm fixture; git -C "$src" remote add origin git@github.com:rcortese/the-ai-crowd-hermes.git
rev=$(git -C "$src" rev-parse HEAD); tree=$(git -C "$src" rev-parse 'HEAD^{tree}'); image=sha256:b80f5a9a93faa6dea369b2c37648753110a3126eae24ff821065fe89e65628fb; receipt=$fx/receipt.json
jq -nc --arg r "$rev" --arg t "$tree" --arg i "$image" --arg e "$(sha256sum "$src/ops/scripts/hddt-moss.sh"|cut -d' ' -f1)" --arg l "$(sha256sum "$src/ops/scripts/hddt-moss-launcher.sh"|cut -d' ' -f1)" --arg b "$(sha256sum "$src/ops/scripts/build-moss-all-in-one-candidate.sh"|cut -d' ' -f1)" '{source_revision:$r,source_tree:$t,source_remote:"git@github.com:rcortese/the-ai-crowd-hermes.git",candidate_image_id:$i,executor_sha256:$e,launcher_sha256:$l,builder_sha256:$b}' >"$receipt"; rh=$(sha256sum "$receipt"|cut -d' ' -f1)
target=$fx/hddt-bootstrap-target/the-ai-crowd-hddt; mkdir -p "$(dirname "$target")"
run(){ HDDT_BOOTSTRAP_TEST=1 "$installer" --source-worktree "$src" --source-revision "$rev" --test-source-tree "$tree" --test-target "$1" --test-receipt "$receipt" --test-receipt-sha256 "$rh"; }
fingerprint(){
  { find "$1" -printf '%y:%m:%u:%g:%s:%p\n' | LC_ALL=C sort; find "$1" -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum; } | sha256sum | cut -d' ' -f1
}
expect_unchanged_reject(){
  local label=$1 case_root=$2 before after rc=0
  before=$(fingerprint "$case_root")
  run "$case_root" >/dev/null 2>&1 || rc=$?
  after=$(fingerprint "$case_root")
  [[ $rc != 0 && $before == "$after" ]] || fail "$label rc=$rc before=$before after=$after"
}
run "$target"
[[ $(stat -c '%u:%g:%a' "$target/bin/hddt-moss.sh") == 0:0:700 && $(stat -c '%u:%g:%a' "$target/state/build-receipts/sha256-${image#sha256:}.json") == 0:0:600 ]] || fail custody
[[ $(git -C "$target/release-source" rev-parse HEAD) == "$rev" && $(git -C "$target/release-source" rev-parse 'HEAD^{tree}') == "$tree" && $(git -C "$target/release-source" remote get-url origin) == git@github.com:rcortese/the-ai-crowd-hermes.git ]] || fail release-identity
before=$(fingerprint "$target"); run "$target" >/dev/null; after=$(fingerprint "$target"); [[ $before == "$after" ]] || fail valid-idempotence-mutated
for label in script-tampered receipt-missing receipt-substituted checkout-wrong remote-wrong; do cp -a "$target" "$fx/$label"; done
printf '# adulterated\n' >>"$fx/script-tampered/bin/hddt-moss.sh"; expect_unchanged_reject script-tampered "$fx/script-tampered"
rm "$fx/receipt-missing/state/build-receipts/sha256-${image#sha256:}.json"; expect_unchanged_reject receipt-missing "$fx/receipt-missing"
printf '{}\n' >"$fx/receipt-substituted/state/build-receipts/sha256-${image#sha256:}.json"; chmod 600 "$fx/receipt-substituted/state/build-receipts/sha256-${image#sha256:}.json"; expect_unchanged_reject receipt-substituted "$fx/receipt-substituted"
wrong_rev=$(git -C "$fx/checkout-wrong/release-source" -c user.name=test -c user.email=test@example.invalid commit-tree HEAD^{tree} -p HEAD -m wrong-revision); git -C "$fx/checkout-wrong/release-source" update-ref HEAD "$wrong_rev"; expect_unchanged_reject checkout-wrong "$fx/checkout-wrong"
git -C "$fx/remote-wrong/release-source" remote set-url origin git@example.invalid:wrong.git; expect_unchanged_reject remote-wrong "$fx/remote-wrong"
rm -rf -- "$target"; bad=${rh/a/b}; rc=0; HDDT_BOOTSTRAP_TEST=1 "$installer" --source-worktree "$src" --source-revision "$rev" --test-source-tree "$tree" --test-target "$target" --test-receipt "$receipt" --test-receipt-sha256 "$bad" >/dev/null 2>&1 || rc=$?; [[ $rc != 0 && ! -e $target ]] || fail bad-receipt-new-root
ln -s /tmp "$target"; rc=0; run "$target" >/dev/null 2>&1 || rc=$?; [[ $rc != 0 && -L $target ]] || fail symlink; rm "$target"
if grep -Eq '\b(docker|compose)\b' "$installer"; then fail lifecycle-token; else rc=$?; [[ $rc == 1 ]] || fail lifecycle-token-scan-error; fi
printf 'bootstrap-test: PASS happy=yes existing-idempotence=yes reds=7 nonmutation=yes no-docker-compose=yes\n'
