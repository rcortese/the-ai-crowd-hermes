#!/usr/bin/env bash
# Semantic mutation gate. Every mutant is a syntax-valid, env -i execution in its own /tmp root.
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
base="$root/ops/scripts/hddt-moss.sh"
moss_test="$root/ops/tests/test_hddt_moss.sh"
binding="$root/ops/scripts/validate-moss-release-binding.sh"
binding_test="$root/ops/tests/test_validate_moss_release_binding.sh"
adapter="$root/ops/scripts/validate-moss-native-conversation.sh"
[[ -f $base && -f $moss_test && -f $binding && -f $binding_test && -f $adapter ]] || exit 66

fail(){ printf 'MUTATION ASSERT: %s\n' "$*" >&2; exit 1; }
show(){ while IFS= read -r line || [[ -n $line ]]; do printf '%s\n' "$line" >&2; done <"$1"; }
ledger_dir=$(mktemp -d /tmp/hddt-mutation-ledger.XXXXXX)
ledger_tsv="$ledger_dir/ledger.tsv"
ledger_rows="$ledger_dir/rows.tsv"
ledger_json="$ledger_dir/ledger.json"
trap 'rm -rf -- "$ledger_dir"' EXIT
printf 'schema\tcohort\tid\tcase_id\ttarget\toracle\tresult\trc\n' >"$ledger_tsv"
: >"$ledger_rows"

run_red(){
  local cohort=$1 name=$2 case_id=$3 source=$4 mode=$5 expected=$6 old=$7 new=$8 anchor=${9:-}
  local dir mutant text prefix suffix rc=0 runner output reached=0 target
  dir=$(mktemp -d "/tmp/hddt-mutation-${name}.XXXXXX")
  mutant="$dir/mutant.sh"
  cp -- "$source" "$mutant"
  chmod 700 "$mutant"
  text=$(<"$mutant")
  [[ $text == *"$old"* ]] || fail "$name mutation target missing"
  prefix=${text%%"$old"*}
  suffix=${text#*"$old"}
  if [[ -n $anchor ]]; then
    [[ $text == *"$anchor(){"* && ${text#*"$anchor(){"} == *"$old"* ]] || fail "$name anchor/slice missing: $anchor"
  fi
  [[ $suffix != *"$old"* ]] || fail "$name mutation target is not unique"
  printf '%s%s%s' "$prefix" "$new" "$suffix" >"$mutant"
  bash -n "$mutant" || fail "$name produced invalid Bash"
  output="$dir/output"
  case $mode in
    hddt) env -i PATH="$PATH" HDDT_SCRIPT="$mutant" bash "$moss_test" --case "$case_id" >"$output" 2>&1 || rc=$? ;;
    adapter) env -i PATH="$PATH" HDDT_ADAPTER_SCRIPT="$mutant" bash "$moss_test" --case "$case_id" >"$output" 2>&1 || rc=$? ;;
    binding) env -i PATH="$PATH" bash "$binding_test" "$mutant" >"$output" 2>&1 || rc=$? ;;
    test-set-e)
      runner="$dir/root/ops/tests/test_hddt_moss.sh"
      mkdir -p "$dir/root/ops/tests"
      ln -s "$root/ops/scripts" "$dir/root/ops/scripts"
      mv "$mutant" "$runner"
      mutant=$runner
      env -i PATH="$PATH" bash "$runner" --case "$case_id" >"$output" 2>&1 || rc=$?
      ;;
    *) fail "$name has unknown mutation mode $mode" ;;
  esac
  (( rc != 0 )) || { printf 'mutant output:\n' >&2; show "$output"; fail "$name stayed green for $case_id"; }
  if [[ $mode == binding ]]; then
    reached=1 # The exact validator reason below is the binding harness reach marker.
  elif [[ $name == functional-endpoint ]]; then
    grep -Fq 'REACH[t81-functional-endpoint]' "$output" && reached=1
  else
    grep -Fq 'FIXTURE_PRESERVED=' "$output" && reached=1
  fi
  (( reached == 1 )) || { printf 'mutant output:\n' >&2; show "$output"; fail "$name did not reach the isolated fixture"; }
  grep -Fq -- "$expected" "$output" || { printf 'mutant output:\n' >&2; show "$output"; fail "$name missed exact oracle: $expected"; }
  if grep -Eiq 'syntax error|command not found|No such file or directory|unbound variable' "$output"; then
    [[ $name == rollback-render-tag || $name == trap-omit-rollback || $name == outbox-before-terminal || $name == signal-rollback-return-status ]] && grep -Fq '/terminal.json: No such file or directory' "$output" || { printf 'mutant output:\n' >&2; show "$output"; fail "$name failed through syntax/setup"; }
  fi
  if [[ $name == functional-endpoint ]]; then
    printf '%s\n' 'REACH[t81-functional-endpoint] ASSERT[t81] causal=true'
  fi
  target=$(basename "$source")${anchor:+:$anchor}
  printf 'hddt-mutation-ledger/v1\t%s\t%s\t%s\t%s\t%s\tRED\t%s\n' "$cohort" "$name" "$case_id" "$target" "$expected" "$rc" >>"$ledger_rows"
  printf 'MUTATION PASS cohort=%s name=%s case=%s syntax=PASS reached=PASS killed=PASS rc=%s\n' "$cohort" "$name" "$case_id" "$rc"
  rm -rf -- "$dir"
}

# Existing seven mutants remain independently causal.
run_red existing env-scrub T10 "$base" hddt 'ASSERT[t10]' 'env -i HOME=/root PATH="$PATH" MOSS_IMAGE_REF="$image" "$db" compose' 'env HOME=/root PATH="$PATH" MOSS_IMAGE_REF="$image" "$db" compose'
run_red existing input-drift T51 "$base" hddt 'ASSERT[t51]' '[[ $before == "$after" ]]||die '\''live inputs drifted before seal'\'' 65' ': # mutation: accept pre-seal drift'
run_red existing authorization-single-use T44 "$base" hddt 'ASSERT[t44]' 'validate_auth "$auth"||{' 'true||{'
run_red existing confirmation-deadline T69 "$base" hddt 'ASSERT[t69]' 'deadline_valid "$op" 1||die' 'true||die'
run_red existing release-argv T12 "$base" hddt 'ASSERT[t12]' 'up -d --no-build --no-deps --force-recreate "$SERVICE"' 'up -d --no-deps --force-recreate "$SERVICE"'
run_red existing container-curl-argv T13 "$base" hddt 'ASSERT[t13]' '/usr/bin/curl --fail --silent --show-error --max-time 5' '/usr/bin/curl --fail --show-error --max-time 5'
run_red existing third-state-recovery T38 "$base" hddt 'ASSERT[t38]' 'terminal "$op" RECOVERY_UNRESOLVED third_state; fi;;' 'terminal "$op" ROLLED_BACK third_state; fi;;'

# Lote A: separate causal mutants for the specified control boundaries.
run_red lote-a base-binding T06 "$base" hddt 'ASSERT[t06]: receipt-base-binding-accepted' '.base_image==$base and .source_closure_sha256==$closure' '.base_image==$base or .source_closure_sha256==$closure'
run_red lote-a authorization-base-binding T83 "$base" hddt 'ASSERT[t83]: authorization-base-binding-accepted' '.moss_base_image==$base and .source_revision==$rev' 'true and .source_revision==$rev'
run_red lote-a selector-tag-default T00 "$binding" binding "ERROR: Compose did not bind Moss to expected immutable image sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" 'MOSS_IMAGE_REF="$1" docker compose' 'MOSS_IMAGE_REF=fixture/moss:local docker compose'
run_red lote-a reopen-live-input-post-seal T51 "$base" hddt 'ASSERT[t51]' '-f "$op/$kind.rendered.json" up -d' '-f "$(stack)/compose.yaml" up -d'
run_red lote-a health-none T08 "$base" hddt 'ASSERT[t08]: health-none-admitted' 'j=$(live); jq -e --arg image "$rollback_image_id" '\''.Image==$image and .State.Running==true and .State.Status=="running" and (.State.Health.Status//"none")=="healthy"'\'' <<<"$j"' 'j=$(live); jq -e --arg image "$rollback_image_id" '\''.Image==$image and .State.Running==true and .State.Status=="running" and (.State.Health.Status//"none")!="unhealthy"'\'' <<<"$j"'
run_red lote-a set-E-nested-err T76 "$moss_test" test-set-e 'ASSERT[t76]: nested-ERR-handler' $'#!/usr/bin/env bash\n# Causal fake-first HDDT matrix. Every Txx runs in an isolated process/root.\nset -Eeuo pipefail' $'#!/usr/bin/env bash\n# Causal fake-first HDDT matrix. Every Txx runs in an isolated process/root.\nset -euo pipefail'
run_red lote-a functional-endpoint T81 "$adapter" adapter 'ASSERT[t81]' 'and ([.[]|select(.event=="done")][0].session.session_id)==$s' 'and (([.[]|select(.event=="done")][0].session.session_id // [.[]|select(.event=="done")][0].session_id)==$s)'
run_red lote-a host-container-vantage T13 "$base" hddt 'ASSERT[t13]' '"$cb" --fail --silent --show-error --max-time 5 http://127.0.0.1:8644/health' '"$db" exec "$before_id" /usr/bin/curl --fail --silent --show-error --max-time 5 http://127.0.0.1:8644/health'
run_red lote-a apply-env-i T12 "$base" hddt 'ASSERT[t12]' 'env -i HOME=/root PATH="$PATH" "$db" compose --project-directory' 'env HOME=/root PATH="$PATH" "$db" compose --project-directory'
run_red lote-a mount-overlap T74 "$base" hddt 'ASSERT[t74]: mount-overlap-rejected' 'all(.[]; .Source as $s | (($s==$r) or ($s|startswith($r+"/")) or ($r|startswith($s+"/")))|not)' 'true'
run_red lote-a parser-eval-injection T75 "$base" hddt 'ASSERT[t75]: parser-no-side-effect' '--operation-id) operation_id=$2;;' '--operation-id) eval "operation_id=$2";;'

# Lote B: rollback rendering, recovery identity, CAS, signal, durability, and preapply boundaries.
run_red lote-b rollback-render-tag T19 "$base" hddt 'ASSERT[t19]' 'expected=$([[ $kind == candidate ]]&&printf %s "$candidate_image_id"||printf %s "$rollback_image_id");' 'expected=$([[ $kind == candidate ]]&&printf %s "$candidate_image_id"||printf %s fixture/moss:rollback);' apply_render
run_red lote-b recovery-image-only-third T80 "$base" hddt 'ASSERT[t80]: recovery-image-only-third' '.image_id==$live.Image and .container_id==$live.Id and .started_at==$live.State.StartedAt and .restart_count==$live.RestartCount and .expected_running==$live.State.Running' '.image_id==$live.Image and .expected_running==$live.State.Running' candidate_matches
run_red lote-b cas-ignore-id T55 "$base" hddt 'ASSERT[t55]' 'and .container_id==$live.Id and .started_at==$live.State.StartedAt' 'and .started_at==$live.State.StartedAt' candidate_matches
run_red lote-b cas-ignore-started-at T56 "$base" hddt 'ASSERT[t56]' 'and .container_id==$live.Id and .started_at==$live.State.StartedAt and .restart_count==$live.RestartCount' 'and .container_id==$live.Id and .restart_count==$live.RestartCount' candidate_matches
run_red lote-b cas-ignore-restart-count T57 "$base" hddt 'ASSERT[t57]' 'and .restart_count==$live.RestartCount and .expected_running==$live.State.Running' 'and .expected_running==$live.State.Running' candidate_matches
run_red lote-b trap-omit-rollback T63 "$base" hddt 'ASSERT[t63]' 'candidate) rollback_live "$CURRENT_OP" "$reason"||true ;;' 'candidate) : ;;' finalize_interruption
run_red lote-b trap-duplicate-rollback T63 "$base" hddt 'ASSERT[t63]' 'if apply_render "$op" rollback && probe_once "$op" rollback; then' 'if apply_render "$op" rollback && probe_once "$op" rollback && apply_render "$op" rollback && probe_once "$op" rollback; then' rollback_live
run_red lote-b outbox-before-terminal T77 "$base" hddt 'ASSERT[t77]: terminal-before-outbox' $'jq -nc --arg s "$state" --arg r "$reason" --argjson t "$(now)" \'{state:$s,reason:$r,created_epoch:$t}\'|atomic_new "$op/terminal.json"; [[ -s $op/terminal.json ]]||die \'terminal durability failure\' 74; jq -nc --arg op "$(basename "$op")" --arg s "$state" --arg h "$(sha "$op/terminal.json")" \'{operation_id:$op,state:$s,terminal_sha256:$h}\'|atomic_new "$r/outbox/$(basename "$op").ready"||die \'terminal outbox publication failure\' 74;' $'jq -nc --arg op "$(basename "$op")" --arg s "$state" --arg h "$(sha "$op/terminal.json")" \'{operation_id:$op,state:$s,terminal_sha256:$h}\'|atomic_new "$r/outbox/$(basename "$op").ready"||die \'terminal outbox publication failure\' 74; jq -nc --arg s "$state" --arg r "$reason" --argjson t "$(now)" \'{state:$s,reason:$r,created_epoch:$t}\'|atomic_new "$op/terminal.json"; [[ -s $op/terminal.json ]]||die \'terminal durability failure\' 74;' terminal_locked
run_red lote-b rollback-preapply-incomplete T79 "$base" hddt 'ASSERT[t79]: rollback-preapply-incomplete' 'PREPARED|AUTHORIZED|VALIDATING|SNAPSHOTTING)' 'AUTHORIZED|VALIDATING|SNAPSHOTTING)' recover
run_red lote-b signal-rollback-return-status T67 "$base" hddt 'ASSERT[t67]' "printf '%s\\n' rollback; return 0;" "printf '%s\\n' rollback; return 1;" signal_relation
run_red lote-b source-base-ancestry T82 "$base" hddt 'ASSERT[t82]' 'merge-base --is-ancestor "$base" "$source_revision"||die' 'true||die' check_receipt
run_red lote-b run-source-base-revalidation T82 "$base" hddt 'ASSERT[t82]' 'release_sr=$(release_source); closure=$(check_source "$release_sr"); check_receipt "$r" "$release_sr" "$closure" >/dev/null; load_request "$op";' 'release_sr=$(release_source); closure=$(check_source "$release_sr"); : # mutation: omit run receipt revalidation
 load_request "$op";' run

jq -Rn --arg schema hddt-mutation-ledger/v1 '
  [inputs | split("\t") | {schema:.[0],cohort:.[1],id:.[2],case_id:.[3],target:.[4],oracle:.[5],result:.[6],rc:(.[7]|tonumber)}]
  | {schema:$schema, mutants:.}
' <"$ledger_rows" >"$ledger_json"
while IFS= read -r line || [[ -n $line ]]; do printf '%s\n' "$line"; done <"$ledger_rows" >>"$ledger_tsv"
jq -e '
  .schema=="hddt-mutation-ledger/v1"
  and (.mutants|length)==30
  and ([.mutants[].id]|unique|length)==30
  and ([.mutants[]|select(.cohort=="existing")]|length)==7
  and ([.mutants[]|select(.cohort=="lote-a")]|length)==11
  and ([.mutants[]|select(.cohort=="lote-b")]|length)==12
  and ([.mutants[].result]|all(.=="RED"))
  and ([.mutants[].id]|sort)==(["apply-env-i","authorization-base-binding","authorization-single-use","base-binding","cas-ignore-id","cas-ignore-restart-count","cas-ignore-started-at","confirmation-deadline","container-curl-argv","env-scrub","functional-endpoint","health-none","host-container-vantage","input-drift","mount-overlap","outbox-before-terminal","parser-eval-injection","recovery-image-only-third","release-argv","reopen-live-input-post-seal","rollback-preapply-incomplete","rollback-render-tag","run-source-base-revalidation","selector-tag-default","set-E-nested-err","signal-rollback-return-status","source-base-ancestry","third-state-recovery","trap-duplicate-rollback","trap-omit-rollback"]|sort)
' "$ledger_json" >/dev/null || fail 'ledger coverage/schema validation failed'
printf '%s\n' 'MUTATION_LEDGER_TSV_BEGIN'
while IFS= read -r line || [[ -n $line ]]; do printf '%s\n' "$line"; done <"$ledger_tsv"
printf '%s\n' 'MUTATION_LEDGER_JSON_BEGIN'
jq -cS . "$ledger_json"
HDDT_SCRIPT="$base" bash "$moss_test" mutations
printf '%s\n' 'hddt-mutations: PASS semantic-red=true ledger-schema=hddt-mutation-ledger/v1 total=30 existing=7 lote-a=11 lote-b=12'