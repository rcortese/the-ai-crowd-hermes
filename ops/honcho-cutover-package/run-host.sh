#!/usr/bin/env bash
# Manual root operator entrypoint. Never changes execution guards or receipts.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
unset CDPATH ENV BASH_ENV PYTHONPATH PYTHONHOME DOCKER_HOST DOCKER_CONTEXT
umask 077
BASE=sha256:9ed081da116daa3036ac32bd06b8a0069eaec540ad6239de4611c7a6df9ecf97
DB_IMAGE=sha256:f115a941954a11bc65040aa0295a4b1849c5ff553df0bb5c7be5e01c6271338a
MOSS=the-ai-crowd-moss-1
STACK=/mnt/user/appdata/the-ai-crowd
HOME_ROOT=$STACK/runtime/moss-home-moss-t0-callsite-fix-20260912T215802Z-86984ab85c31
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PY=/opt/hermes/.venv/bin/python
MODE=${1:-plan}
if [[ $# -gt 1 || ! $MODE =~ ^(plan|prepare|apply|verify)$ ]]; then
  printf 'Uso: bash run-host.sh [plan|prepare|apply|verify]\n' >&2; exit 64
fi
[[ $EUID -eq 0 ]] || { printf 'Execute como root no MEDIA.\n' >&2; exit 77; }
[[ $(hostname) == MEDIA ]] || { printf 'Host incorreto.\n' >&2; exit 78; }
[[ $ROOT == /root/honcho-cutover-final ]] || { printf 'Copie o pacote para /root/honcho-cutover-final.\n' >&2; exit 78; }
docker() { command docker --host unix:///var/run/docker.sock "$@"; }
stackgit() { command git -c safe.directory=/mnt/ssd/appdata/the-ai-crowd -C "$STACK" "$@"; }
packagegit() { command git -c safe.directory="$ROOT" -C "$ROOT" "$@"; }
compose() { docker compose --project-directory "$STACK" -f "$STACK/compose.yaml" "$@"; }
REV=$(packagegit rev-parse HEAD)
[[ -z $(packagegit status --porcelain) ]] || { printf 'Pacote alterado; recuse executar.\n' >&2; exit 78; }
STATE=$STACK/state/private/backups/honcho-cutover/$REV
KEY=$STACK/state/private/backup-keys/honcho-cutover-$REV.key
CLONE=moss-honcho-rehearsal-${REV:0:12}
TAG=moss-honcho-candidate:${REV:0:12}
exec 9>/run/lock/moss-honcho-cutover.lock
flock -n 9 || { printf 'Outra execução está ativa.\n' >&2; exit 75; }

probe() { docker exec -i "$MOSS" "$PY" - "$1" < "$ROOT/runtime_probe.py"; }
check_installed() {
  docker exec -i "$MOSS" sha256sum -c - < "$ROOT/INSTALLED.sha256"
  probe installed
}
files() {
  docker run --rm --network none --entrypoint "$PY" \
    --mount type=bind,src="$ROOT",dst=/package,readonly \
    --mount type=bind,src="$STACK",dst=/stack \
    --mount type=bind,src="$HOME_ROOT",dst=/target-home \
    --mount type=bind,src="$STATE",dst=/state \
    "$BASE" /package/host_ops.py "$@"
}
crypto() {
  docker run --rm -i --network none --entrypoint "$PY" \
    --mount type=bind,src="$ROOT",dst=/package,readonly \
    --mount type=bind,src="$KEY",dst=/key,readonly \
    "$BASE" /package/backup_stream.py "$1" /key
}
healthy() {
  local deadline=$((SECONDS+240))
  while (( SECONDS < deadline )); do
    if [[ $(docker inspect "$MOSS" --format '{{.State.Health.Status}}') == healthy ]]; then return; fi
    sleep 3
  done
  printf 'Moss não ficou saudável no prazo.\n' >&2; return 1
}
preflight() {
  [[ $(docker inspect "$MOSS" --format '{{.Image}}') == "$BASE" ]] || { printf 'Imagem Moss divergente.\n' >&2; return 1; }
  [[ $(docker inspect honcho-database-1 --format '{{.Image}}') == "$DB_IMAGE" ]] || return 1
  [[ $(docker inspect "$MOSS" --format '{{index .Config.Labels "com.docker.compose.service"}}') == moss ]] || return 1
  [[ $(docker inspect "$MOSS" --format '{{range .Mounts}}{{if eq .Destination "/opt/data"}}{{.Source}}{{end}}{{end}}') == "$HOME_ROOT" ]] || return 1
  [[ -z $(stackgit status --porcelain) ]] || { printf 'Repositório da stack está alterado.\n' >&2; return 1; }
  stackgit var GIT_AUTHOR_IDENT >/dev/null
  compose config --quiet
  (cd "$ROOT" && sha256sum -c SHA256SUMS)
  docker exec -i "$MOSS" sha256sum -c - < "$ROOT/BASELINE.sha256"
  probe baseline
  docker exec -i honcho-database-1 psql -U postgres -d postgres < "$ROOT/verify_fresh.sql"
  # Verify Luna at the source of record. Never print the credential-bearing file.
  docker run --rm --network none --entrypoint "$PY" \
    --mount type=bind,src=/mnt/user/appdata/honcho/litellm-config.yaml,dst=/models.yaml,readonly \
    "$BASE" -c 'import yaml; c=yaml.safe_load(open("/models.yaml")); models={x["model_name"]:x["litellm_params"]["model"] for x in c["model_list"]}; assert models["honcho-memory-fast"]=="chatgpt/gpt-5.6-luna"; print("Luna binding PASS")'
}

if [[ $MODE == verify ]]; then
  check_installed
  probe configured
  probe channels
  docker exec -i honcho-database-1 psql -U postgres -d postgres < "$ROOT/verify_legacy.sql"
  printf 'Instalação, configuração ativa, canais, dreaming e ausência do legado próprio verificados.\n'
  exit 0
fi
preflight
if [[ $MODE == plan ]]; then
  printf 'Plano validado, sem mudanças: build/testes isolados; backup cifrado+restore; Moss-only cutover; login novo WebUI e /new Telegram; aceite humano nos dois canais; dreaming nativo; limpeza transacional do legado próprio.\n'
  printf 'apply interrompe brevemente Moss/WebUI/Telegram e, na limpeza, o deriver do Honcho. Não modifica guards nem outras personas.\n'
  exit 0
fi
mkdir -p -- "$STATE" "$(dirname -- "$KEY")"
chmod 700 "$STATE" "$(dirname -- "$KEY")"
[[ ! -e $STATE/completed ]] || { printf 'Transação já concluída. Use verify.\n'; exit 78; }
# Phase-aware rollback never recreates Moss after an offline-only failure.
source_changed=0
staging_started=0
source_imported=0
promotion_committed=0
lifecycle_started=0
legacy_committed=0
deriver_stopped=0
cleanup() {
  local result=$?
  trap - EXIT INT TERM
  if docker inspect "$CLONE" >/dev/null 2>&1; then
    if [[ $(docker inspect "$CLONE" --format '{{index .Config.Labels "moss.honcho.package"}}') == "$REV" ]]; then docker rm -f -v "$CLONE" >/dev/null || true; fi
  fi
  if (( deriver_stopped )); then docker start honcho-deriver-1 >/dev/null || result=1; fi
  if (( result != 0 && staging_started && ! legacy_committed )); then
    if [[ -f $HOME_ROOT/honcho.json ]]; then files disable || result=1; fi
  fi
  if (( result != 0 && source_changed && ! legacy_committed )); then
    printf 'Falha: desabilitando ingestão e restaurando somente a imagem/Compose do Moss.\n' >&2
    if files rollback-compose; then
      if (( ! promotion_committed )); then stackgit reset -- ops/honcho-cutover-package || true; fi
      stackgit add -- compose.yaml
      stackgit commit -m 'rollback(moss): restore pre-Honcho image after failed acceptance' || true
      if (( lifecycle_started )); then
        live_image=$(docker inspect "$MOSS" --format '{{.Image}}')
        if [[ $live_image == "$BASE" || $live_image == "$CANDIDATE" ]]; then
          compose up -d --no-deps --no-build --timeout 120 moss && healthy || result=1
        else
          printf 'Imagem mudou por outra operação; rollback de lifecycle recusado.\n' >&2
          result=1
        fi
      fi
    else
      printf 'Rollback recusado por divergência de source; intervenção manual necessária.\n' >&2
    fi
  fi
  if (( result != 0 && staging_started && ! legacy_committed )); then
    files unstage || result=1
    printf 'Conversas novas autorizadas foram preservadas. Se houve ingestão, não repita apply: reconcilie moss-rodolfo antes de uma nova tentativa; o preflight vazio recusará reexecução.\n' >&2
  fi
  if (( result != 0 && source_imported && ! promotion_committed )); then
    if (cd "$STACK/ops/honcho-cutover-package" && sha256sum -c SHA256SUMS >/dev/null); then
      stackgit reset -- ops/honcho-cutover-package || true
      failed_source=$(mktemp -d "$STATE/source.failed.XXXXXX")
      mv -- "$STACK/ops/honcho-cutover-package" "$failed_source/tree"
    fi
  fi
  if (( result != 0 && legacy_committed )); then
    printf 'Limpeza já confirmada. Não restaure o banco inteiro sobre mudanças de outras personas; backup cifrado em %s.\n' "$STATE" >&2
  fi
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# No production restarts in prepare. The exact running base is pinned above.
BASE_TAG=moss-honcho-base:${REV:0:12}
if docker image inspect "$BASE_TAG" >/dev/null 2>&1; then
  [[ $(docker image inspect "$BASE_TAG" --format '{{.Id}}') == "$BASE" ]] || exit 78
else
  docker tag "$BASE" "$BASE_TAG"
fi
docker build --pull=false --build-arg BASE_IMAGE="$BASE_TAG" --tag "$TAG" "$ROOT"
[[ $(docker image inspect "$BASE_TAG" --format '{{.Id}}') == "$BASE" ]] || exit 78
CANDIDATE=$(docker image inspect "$TAG" --format '{{.Id}}')
docker run --rm --network none --entrypoint "$PY" -e PYTHONPATH=/opt/hermes "$CANDIDATE" \
  -m pytest -q /opt/moss-honcho-package/tests
if [[ ! -e $KEY ]]; then openssl rand -out "$KEY" 32; chmod 600 "$KEY"; fi
[[ -f $KEY && ! -L $KEY && $(stat -c %U "$KEY") == root && $(stat -c %a "$KEY") == 600 ]] || exit 78
# Always take a new pre-execution consistent snapshot, not a predecessor backup.
docker exec honcho-database-1 pg_dump -U postgres -d postgres -Fc --no-owner | crypto encrypt > "$STATE/database.dump.gcm.new"
mv -- "$STATE/database.dump.gcm.new" "$STATE/database.dump.gcm"
sha256sum "$STATE/database.dump.gcm" > "$STATE/database.dump.gcm.sha256"
docker run -d --name "$CLONE" --network none --label moss.honcho.package="$REV" \
  --tmpfs /var/lib/postgresql/data:rw,size=2g -e POSTGRES_HOST_AUTH_METHOD=trust "$DB_IMAGE" >/dev/null
deadline=$((SECONDS+60))
until docker exec "$CLONE" pg_isready -U postgres >/dev/null; do
  (( SECONDS < deadline )) || exit 1
  sleep 1
done
crypto decrypt < "$STATE/database.dump.gcm" | docker exec -i "$CLONE" pg_restore -U postgres -d postgres --no-owner --exit-on-error
docker exec -i "$CLONE" psql -U postgres -d postgres < "$ROOT/verify_fresh.sql" > "$STATE/fresh-rehearsal.txt"
docker exec "$CLONE" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c "CREATE TABLE public.moss_cutover_freshness_probe(workspace_name text); INSERT INTO public.moss_cutover_freshness_probe VALUES ('moss-rodolfo');" >> "$STATE/fresh-rehearsal.txt"
if docker exec -i "$CLONE" psql -U postgres -d postgres < "$ROOT/verify_fresh.sql" > "$STATE/fresh-negative.txt" 2>&1; then
  printf 'Teste negativo de memória órfã falhou.\n' >&2; exit 1
fi
docker exec "$CLONE" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c 'DROP TABLE public.moss_cutover_freshness_probe' >> "$STATE/fresh-rehearsal.txt"
docker exec -i "$CLONE" psql -U postgres -d postgres < "$ROOT/verify_fresh.sql" >> "$STATE/fresh-rehearsal.txt"
docker exec -i "$CLONE" psql -U postgres -d postgres < "$ROOT/retire_legacy.sql" > "$STATE/rehearsal.txt"
docker exec -i "$CLONE" psql -U postgres -d postgres < "$ROOT/retire_legacy.sql" >> "$STATE/rehearsal.txt"
docker exec -i "$CLONE" psql -U postgres -d postgres < "$ROOT/verify_legacy.sql" >> "$STATE/rehearsal.txt"
docker rm -f -v "$CLONE" >/dev/null
printf 'Preparação concluída: testes, backup cifrado, restauração e limpeza idempotente na cópia.\n'
if [[ $MODE == prepare ]]; then exit 0; fi

# Last live identity check immediately before canonical promotion.
preflight
printf 'O próximo passo recria SOMENTE Moss, interrompendo brevemente seus canais.\n'
read -r -p 'Digite APLICAR para prosseguir: ' confirm
[[ $confirm == APLICAR ]] || exit 1
probe idle
if [[ -e $STACK/ops/honcho-cutover-package ]]; then
  cmp "$ROOT/SHA256SUMS" "$STACK/ops/honcho-cutover-package/SHA256SUMS"
  (cd "$STACK/ops/honcho-cutover-package" && sha256sum -c SHA256SUMS >/dev/null)
else
  source_stage=$(mktemp -d "$STATE/source.stage.XXXXXX")
  packagegit archive HEAD | tar -x -C "$source_stage"
  mv -- "$source_stage" "$STACK/ops/honcho-cutover-package"
  source_imported=1
fi
source_changed=1
files compose "$CANDIDATE"
compose config --quiet
stackgit add -- compose.yaml ops/honcho-cutover-package
stackgit commit -m "feat(moss): install authenticated Honcho integration $REV"
promotion_committed=1
staging_started=1
files stage
lifecycle_started=1
compose up -d --no-deps --no-build --timeout 120 moss
healthy
[[ $(docker inspect "$MOSS" --format '{{.Image}}') == "$CANDIDATE" ]] || exit 1
check_installed
files enable
printf '\nAgora faça novo login por senha no WebUI e abra uma conversa nova; no Telegram use /new.\n'
printf 'Em cada canal, informe uma preferência real que queira memorizar. Em conversas novas no outro canal, peça para recuperá-la. Não use segredos.\n'
read -r -p 'Após confirmar recuperação nos dois sentidos, digite RECUPERACAO_CONFIRMADA: ' confirm
[[ $confirm == RECUPERACAO_CONFIRMADA ]] || exit 1
printf 'operator_attestation=bidirectional_recall_confirmed\npackage_revision=%s\n' "$REV" > "$STATE/human-channel-attestation.txt"
probe channels
probe dream
[[ $(docker inspect "$MOSS" --format '{{.Image}}') == "$CANDIDATE" ]] || exit 1
# The irreversible owned-legacy cleanup is last. Other observers remain intact.
deriver_stopped=1
docker stop --time 90 honcho-deriver-1 >/dev/null
[[ $(docker inspect honcho-deriver-1 --format '{{.State.Running}}') == false ]] || exit 1
docker exec -i honcho-database-1 psql -U postgres -d postgres < "$ROOT/retire_legacy.sql" > "$STATE/legacy-cleanup.txt"
legacy_committed=1
docker exec -i honcho-database-1 psql -U postgres -d postgres < "$ROOT/verify_legacy.sql" >> "$STATE/legacy-cleanup.txt"
docker start honcho-deriver-1 >/dev/null
deriver_stopped=0
[[ $(docker inspect honcho-deriver-1 --format '{{.State.Running}}') == true ]] || exit 1
check_installed
probe configured
probe channels
healthy
# A failed push is reported without rolling back a working memory or restoring legacy.
stackgit push
printf '%s\n' "$CANDIDATE" > "$STATE/completed"
printf 'Concluído: ingestão confirmada por API nos dois canais; recuperação cruzada atestada pelo operador; dreaming habilitado; legado próprio removido.\n'
printf 'Referências de outras personas a Moss e nós relacionais inativos foram preservados.\n'
printf 'Evidência/backup: %s\nChave separada: %s\n' "$STATE" "$KEY"
