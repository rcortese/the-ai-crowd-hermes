#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd); installer=$root/ops/scripts/bootstrap-hddt-moss-root.sh
fail(){ printf 'bootstrap-test: RED %s\n' "$*" >&2; exit 1; }
fx=$(mktemp -d /tmp/hddt-bootstrap-test.XXXXXX); trap 'rm -rf -- "$fx"' EXIT
src=$fx/source; mkdir -p "$src/ops/scripts" "$src/ops/cron"
cp "$root/ops/cron/the-ai-crowd-hddt-retention.cron" "$src/ops/cron/"
for p in hddt-moss.sh hddt-moss-launcher.sh hddt-moss-status.sh build-moss-all-in-one-candidate.sh; do printf '#!/usr/bin/env bash\n# %s\nexit 0\n' "$p" >"$src/ops/scripts/$p"; chmod 755 "$src/ops/scripts/$p"; done
git init -q "$src"; git -C "$src" config user.email test@example.invalid; git -C "$src" config user.name test; git -C "$src" add .; git -C "$src" commit -qm fixture; git -C "$src" remote add origin git@github.com:rcortese/the-ai-crowd-hermes.git
rev=$(git -C "$src" rev-parse HEAD); tree=$(git -C "$src" rev-parse 'HEAD^{tree}'); image=sha256:1111111111111111111111111111111111111111111111111111111111111111; receipt=$fx/receipt.json
jq -nc --arg r "$rev" --arg t "$tree" --arg i "$image" --arg e "$(sha256sum "$src/ops/scripts/hddt-moss.sh"|cut -d' ' -f1)" --arg l "$(sha256sum "$src/ops/scripts/hddt-moss-launcher.sh"|cut -d' ' -f1)" --arg b "$(sha256sum "$src/ops/scripts/build-moss-all-in-one-candidate.sh"|cut -d' ' -f1)" '{source_revision:$r,source_tree:$t,source_remote:"git@github.com:rcortese/the-ai-crowd-hermes.git",candidate_image_id:$i,executor_sha256:$e,launcher_sha256:$l,builder_sha256:$b}' >"$receipt"; rh=$(sha256sum "$receipt"|cut -d' ' -f1)
target=$fx/hddt-bootstrap-target/the-ai-crowd-hddt; mkdir -p "$(dirname "$target")"
cron_target=$fx/dynamix/the-ai-crowd-hddt-retention.cron; mkdir -p "$(dirname "$cron_target")" "$fx/bin"
printf '#!/usr/bin/env bash\nset -eu\nprintf "update_cron\\n" >>"%s"\n' "$fx/update-cron.log" >"$fx/bin/update_cron"; chmod +x "$fx/bin/update_cron"
printf '#!/usr/bin/env bash\nset -eu\nc="%s"; n=$(( $(cat "$c" 2>/dev/null || echo 0)+1 )); printf "%%s\\n" "$n" >"$c"; (( n > 1 ))\n' "$fx/update-cron-fail-once.count" >"$fx/bin/update_cron_fail_once"; chmod +x "$fx/bin/update_cron_fail_once"
printf '#!/usr/bin/env bash\nset -eu\nc="%s"; n=$(( $(cat "$c" 2>/dev/null || echo 0)+1 )); printf "%%s\\n" "$n" >"$c"; (( n > 1 )); /usr/bin/sync "$@"\n' "$fx/scheduler-sync-fail-once.count" >"$fx/bin/scheduler_sync_fail_once"; chmod +x "$fx/bin/scheduler_sync_fail_once"
printf '#!/usr/bin/env bash\nset -eu\nc="%s"; n=$(( $(cat "$c" 2>/dev/null || echo 0)+1 )); printf "%%s\\n" "$n" >"$c"; if (( n == 1 )); then rm -f -- "$SABOTAGE_TARGET"; mkdir "$SABOTAGE_TARGET"; exit 1; fi; /usr/bin/sync "$@"\n' "$fx/scheduler-sync-sabotage.count" >"$fx/bin/scheduler_sync_sabotage"; chmod +x "$fx/bin/scheduler_sync_sabotage"
run(){ HDDT_BOOTSTRAP_TEST=1 "$installer" --source-worktree "$src" --source-revision "$rev" --candidate-image-id "$image" --source-tree "$tree" --test-target "$1" --receipt "$receipt" --receipt-sha256 "$rh" --test-cron-target "$cron_target" --test-update-cron "$fx/bin/update_cron"; }
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
[[ -f $cron_target && ! -L $cron_target && $(stat -c '%u:%g:%a' "$cron_target") == 0:0:600 ]] || fail retention-schedule-custody
cmp -s "$cron_target" "$src/ops/cron/the-ai-crowd-hddt-retention.cron" || fail retention-schedule-bytes
[[ $(grep -c '^update_cron$' "$fx/update-cron.log") == 1 ]] || fail retention-schedule-not-activated
[[ $(stat -c '%u:%g:%a' "$target/bin/hddt-moss.sh") == 0:0:700 && $(stat -c '%u:%g:%a' "$target/state/build-receipts/sha256-${image#sha256:}.json") == 0:0:600 ]] || fail custody
[[ $(git -C "$target/release-source" rev-parse HEAD) == "$rev" && $(git -C "$target/release-source" rev-parse 'HEAD^{tree}') == "$tree" && $(git -C "$target/release-source" remote get-url origin) == git@github.com:rcortese/the-ai-crowd-hermes.git ]] || fail release-identity
before=$(fingerprint "$target"); run "$target" >/dev/null; after=$(fingerprint "$target"); [[ $before == "$after" ]] || fail valid-idempotence-mutated
[[ $(grep -c '^update_cron$' "$fx/update-cron.log") == 2 ]] || fail retention-schedule-idempotence-activation
printf 'tampered\n' >"$cron_target"; run "$target" >/dev/null
cmp -s "$cron_target" "$src/ops/cron/the-ai-crowd-hddt-retention.cron" || fail retention-schedule-not-reconciled
[[ $(grep -c '^update_cron$' "$fx/update-cron.log") == 3 ]] || fail retention-schedule-reconciliation-not-activated
rm -f "$cron_target"; ln -s /tmp "$cron_target"; rc=0; run "$target" >/dev/null 2>&1 || rc=$?; [[ $rc != 0 && -L $cron_target ]] || fail retention-schedule-symlink
rm -f "$cron_target"; printf 'prior-schedule\n' >"$cron_target"; chmod 600 "$cron_target"; rm -f "$fx/update-cron-fail-once.count"
before=$(fingerprint "$target"); rc=0; HDDT_BOOTSTRAP_TEST=1 "$installer" --source-worktree "$src" --source-revision "$rev" --candidate-image-id "$image" --source-tree "$tree" --test-target "$target" --receipt "$receipt" --receipt-sha256 "$rh" --test-cron-target "$cron_target" --test-update-cron "$fx/bin/update_cron_fail_once" >/dev/null 2>&1 || rc=$?; after=$(fingerprint "$target")
[[ $rc == 65 && $before == "$after" && $(cat "$cron_target") == prior-schedule && $(cat "$fx/update-cron-fail-once.count") == 2 ]] || fail retention-update-cron-rollback
run "$target" >/dev/null; cmp -s "$cron_target" "$src/ops/cron/the-ai-crowd-hddt-retention.cron" || fail retention-post-rollback-reconciliation
printf 'prior-sync-schedule\n' >"$cron_target"; chmod 600 "$cron_target"; rm -f "$fx/scheduler-sync-fail-once.count"
before=$(fingerprint "$target"); rc=0; HDDT_BOOTSTRAP_TEST=1 "$installer" --source-worktree "$src" --source-revision "$rev" --candidate-image-id "$image" --source-tree "$tree" --test-target "$target" --receipt "$receipt" --receipt-sha256 "$rh" --test-cron-target "$cron_target" --test-update-cron "$fx/bin/update_cron" --test-scheduler-sync "$fx/bin/scheduler_sync_fail_once" >/dev/null 2>&1 || rc=$?; after=$(fingerprint "$target")
[[ $rc == 65 && $before == "$after" && $(cat "$cron_target") == prior-sync-schedule && $(cat "$fx/scheduler-sync-fail-once.count") == 2 ]] || fail retention-sync-rollback
run "$target" >/dev/null; cmp -s "$cron_target" "$src/ops/cron/the-ai-crowd-hddt-retention.cron" || fail retention-post-sync-rollback-reconciliation
printf 'prior-restore-schedule\n' >"$cron_target"; chmod 600 "$cron_target"; rm -f "$fx/scheduler-sync-sabotage.count"
before=$(fingerprint "$target"); rc=0; SABOTAGE_TARGET="$cron_target" HDDT_BOOTSTRAP_TEST=1 "$installer" --source-worktree "$src" --source-revision "$rev" --candidate-image-id "$image" --source-tree "$tree" --test-target "$target" --receipt "$receipt" --receipt-sha256 "$rh" --test-cron-target "$cron_target" --test-update-cron "$fx/bin/update_cron" --test-scheduler-sync "$fx/bin/scheduler_sync_sabotage" >/dev/null 2>&1 || rc=$?; after=$(fingerprint "$target")
[[ $rc == 74 && $before == "$after" && -d $cron_target && $(cat "$fx/scheduler-sync-sabotage.count") == 1 ]] || fail retention-existing-restore-operation-failure
rm -rf -- "$cron_target"; run "$target" >/dev/null
for label in script-tampered receipt-missing receipt-substituted checkout-wrong remote-wrong; do cp -a "$target" "$fx/$label"; done
printf '# adulterated\n' >>"$fx/script-tampered/bin/hddt-moss.sh"; expect_unchanged_reject script-tampered "$fx/script-tampered"
rm "$fx/receipt-missing/state/build-receipts/sha256-${image#sha256:}.json"; expect_unchanged_reject receipt-missing "$fx/receipt-missing"
printf '{}\n' >"$fx/receipt-substituted/state/build-receipts/sha256-${image#sha256:}.json"; chmod 600 "$fx/receipt-substituted/state/build-receipts/sha256-${image#sha256:}.json"; expect_unchanged_reject receipt-substituted "$fx/receipt-substituted"
wrong_rev=$(git -C "$fx/checkout-wrong/release-source" -c user.name=test -c user.email=test@example.invalid commit-tree HEAD^{tree} -p HEAD -m wrong-revision); git -C "$fx/checkout-wrong/release-source" update-ref HEAD "$wrong_rev"; expect_unchanged_reject checkout-wrong "$fx/checkout-wrong"
git -C "$fx/remote-wrong/release-source" remote set-url origin git@example.invalid:wrong.git; expect_unchanged_reject remote-wrong "$fx/remote-wrong"
new_target=$fx/hddt-bootstrap-newfail/the-ai-crowd-hddt; new_cron=$fx/dynamix-newfail/the-ai-crowd-hddt-retention.cron; mkdir -p "$(dirname "$new_target")" "$(dirname "$new_cron")"; rm -f "$fx/update-cron-fail-once.count"
rc=0; HDDT_BOOTSTRAP_TEST=1 "$installer" --source-worktree "$src" --source-revision "$rev" --candidate-image-id "$image" --source-tree "$tree" --test-target "$new_target" --receipt "$receipt" --receipt-sha256 "$rh" --test-cron-target "$new_cron" --test-update-cron "$fx/bin/update_cron_fail_once" >/dev/null 2>&1 || rc=$?
[[ $rc == 65 && ! -e $new_target && ! -e $new_cron && ! -L $new_cron && $(cat "$fx/update-cron-fail-once.count") == 2 ]] || fail new-root-retention-activation-rollback
new_sync_target=$fx/hddt-bootstrap-newsyncfail/the-ai-crowd-hddt; new_sync_cron=$fx/dynamix-newsyncfail/the-ai-crowd-hddt-retention.cron; mkdir -p "$(dirname "$new_sync_target")" "$(dirname "$new_sync_cron")"; rm -f "$fx/scheduler-sync-fail-once.count"
rc=0; HDDT_BOOTSTRAP_TEST=1 "$installer" --source-worktree "$src" --source-revision "$rev" --candidate-image-id "$image" --source-tree "$tree" --test-target "$new_sync_target" --receipt "$receipt" --receipt-sha256 "$rh" --test-cron-target "$new_sync_cron" --test-update-cron "$fx/bin/update_cron" --test-scheduler-sync "$fx/bin/scheduler_sync_fail_once" >/dev/null 2>&1 || rc=$?
[[ $rc == 65 && ! -e $new_sync_target && ! -e $new_sync_cron && ! -L $new_sync_cron && $(cat "$fx/scheduler-sync-fail-once.count") == 2 ]] || fail new-root-retention-sync-rollback
new_restore_target=$fx/hddt-bootstrap-newrestorefail/the-ai-crowd-hddt; new_restore_cron=$fx/dynamix-newrestorefail/the-ai-crowd-hddt-retention.cron; mkdir -p "$(dirname "$new_restore_target")" "$(dirname "$new_restore_cron")"; rm -f "$fx/scheduler-sync-sabotage.count"
rc=0; SABOTAGE_TARGET="$new_restore_cron" HDDT_BOOTSTRAP_TEST=1 "$installer" --source-worktree "$src" --source-revision "$rev" --candidate-image-id "$image" --source-tree "$tree" --test-target "$new_restore_target" --receipt "$receipt" --receipt-sha256 "$rh" --test-cron-target "$new_restore_cron" --test-update-cron "$fx/bin/update_cron" --test-scheduler-sync "$fx/bin/scheduler_sync_sabotage" >/dev/null 2>&1 || rc=$?
[[ $rc == 74 && ! -e $new_restore_target && -d $new_restore_cron && $(cat "$fx/scheduler-sync-sabotage.count") == 1 ]] || fail new-root-retention-restore-operation-failure
rm -rf -- "$new_restore_cron"
rm -f -- "$cron_target"; "$fx/bin/update_cron"
rm -rf -- "$target"; bad=${rh/a/b}; rc=0; HDDT_BOOTSTRAP_TEST=1 "$installer" --source-worktree "$src" --source-revision "$rev" --candidate-image-id "$image" --source-tree "$tree" --test-target "$target" --receipt "$receipt" --receipt-sha256 "$bad" --test-cron-target "$cron_target" --test-update-cron "$fx/bin/update_cron" >/dev/null 2>&1 || rc=$?; [[ $rc != 0 && ! -e $target ]] || fail bad-receipt-new-root
rc=0; HDDT_BOOTSTRAP_TEST=1 "$installer" --source-worktree "$src" --source-revision "$rev" --source-tree "$tree" --test-target "$target" --receipt "$receipt" --receipt-sha256 "$rh" --test-cron-target "$cron_target" --test-update-cron "$fx/bin/update_cron" >/dev/null 2>&1 || rc=$?; [[ $rc == 64 && ! -e $target ]] || fail missing-candidate-binding
ln -s /tmp "$target"; rc=0; run "$target" >/dev/null 2>&1 || rc=$?; [[ $rc != 0 && -L $target ]] || fail symlink; rm "$target"
if grep -Eq '\b(docker|compose)\b' "$installer"; then fail lifecycle-token; else rc=$?; [[ $rc == 1 ]] || fail lifecycle-token-scan-error; fi
printf 'bootstrap-test: PASS happy=yes existing-idempotence=yes retention-scheduler=true scheduler-reds=7 reds=7 nonmutation=yes no-docker-compose=yes\n'
