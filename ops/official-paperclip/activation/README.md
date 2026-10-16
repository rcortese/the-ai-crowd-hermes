# TAC-246 — candidato pequeno Moss (source-only)

**Para revisão independente; não instalado, ativado ou aprovado por este pacote.**
Este diretório pertence ao candidato isolado
`/opt/data/profiles/moss/runtime/execution-candidates/tac246-activation`, branch
`tac246-moss-activation`, clonado com `--no-hardlinks` do HEAD
`353b8029225fc2c8cb5490a24cf2b6e3b480f600` de `tac246-fleet`.
A revisão F1 `67fd517` altera testes/metadados, não os runtime patches/hashes/imagens
`353b802`; a reconciliação desses metadados pertence ao coordenador.

## Delta R1/R2/R4 — revisão ainda pendente

O parecer independente sobre `199d98ea4f67d46a0c067191b90654c70f34afa2`
(tree `a57bc2550a71d925c8bd94ff54ffbac1db323234`) permanece **REQUEST_CHANGES**.
Este delta source-only foi autorizado somente para **R1/P1, R2/P1 e R4/P2**, no
clone independente `/opt/data/profiles/moss/runtime/execution-candidates/tac246-activation-r314dd718`.
O candidato original não foi alterado. **R3/P1 permanece contido, sem bypass;
prontidão operacional BLOCKED.** Correções aqui não são autoaprovação nem ativação.

- **R1:** `child_run` marca seus comandos como supervisionados; `common.command`
  conserva esse PGID, sem abrir outra sessão. Seu cleanup local termina/reapa o
  líder do comando sem matar o executor; o supervisor externo termina/reapa o grupo
  inteiro, inclusive descendentes adotados, antes de `reaped:true`. Comandos fora
  desse envelope conservam seu grupo exclusivo e cleanup próprio. Isso cobre os
  comandos fechados deste pacote, não processos arbitrários que deliberadamente
  daemonizem com `setsid`. O teste composto usa PID real local, timeout externo,
  timeout interno e líder bem-sucedido com descendente; também limpa o caso RED.
  Encerrar Docker CLI **não** prova cancelamento no daemon/container.
- **R2:** o primeiro INTENT conserva CAS do snapshot integral; persiste somente SHA
  da identidade estável real (`id/source/user_id/started_at/parent_session_id/
  is_internal_child`). Recovery lê receipt privado do uid atual antes do preflight,
  revalida capabilities, memória-off e identidade, mas não compara contadores,
  custos, preview ou título com o preimage. `user_id` pode ser null na API real:
  não é atestação fictícia de principal; a autoridade continua o namespace da API
  autenticada no container fixo e o snapshot inicial autorizado. Sem trocar sessão,
  plano, payload, idempotency-key ou run aceito, sem POST em SUBMITTED/COMPLETED.
  Receipts antigos sem binding estável falham fechado; não são migrados/adivinhados.
- **R4:** a contagem do plano é observação externa do catálogo completo, não pin
  histórico. O SDK percorre todas as páginas até `nextCursor is None`, rejeita
  nomes vazios/duplicados, páginas vazias e cursores inválidos/repetidos; calcula
  contagem e digest de todos os nomes e compara ambos com o plano aprovado.
  Aceitar outra cardinalidade no schema **não** certifica completude: catálogo
  reduzido ou página faltante continua falhando no digest/contagem vinculados.
  O catálogo oficial externo ainda não foi fornecido; fixtures não o substituem.

Evidência RED/GREEN e execução local: arquivos no scratch com prefixo
`/opt/data/profiles/moss/cache/scratch/tac246-r314dd718-`.
Parecer/probes/resultados originais preservados sob `tac246-review-199d98e*`.
Novo aceite exige revisão independente do commit/tree/digest deste delta.

## Limite e bloqueios reais

Somente executor de **Moss**, imagem já construída + transformação MCP aprovada.
Não é framework, ponte MCP, kit TAC188, migração de layout ou executor de fleet.
Não importa nem executa `deployment-private/moss/package/deploy.py`, seus plans ou
os runners antigos. Reutiliza os princípios de file-CAS, digest sem valores,
marker nativo com ownership, processo/PGID separado e callback idempotente.

**O backend host não está habilitado para promoção no substrate inspecionado.**
`Host.admission()` recusa `BLOCKED_WEBUI_ADMISSION_ACCOUNTING` antes de criar marker:
o marker nativo fecha gateway/API, mas as interfaces observadas não demonstram
fechamento/accounting completo do owner WebUI independente. `ingresses` é fixo nos
três ingressos: retirar WebUI do plano é erro, não workaround. Não há flag para
ignorar isso, protocolo TAC188 sintético ou patch em Hermes/core. Os fakes fecham
seus próprios ingressos; não certificam esta capacidade no runtime real.

Outro pré-requisito causal obrigatório: o `adapterexecute.ts` oficial no **produtor
Paperclip** é importado por TSX/cacheado no processo. A camada
`sha256:b9ad3a9483657cf25cc345310e1ad0801d926f6e43564c7aba06b5e8bdd416aa`
precisa estar **ativada com reload real do Paperclip e request-context verificado**
antes das configs request-mode. Pin Moss ou layer presente não basta. O executor
exige evidência externa hash-bound e fresca; não faz lifecycle do servidor.

Também faltam plano final, pre/post SHA e custódia atuais, catálogo SHA completo,
sessão API existente correta, auth via ambiente do container e evidência memory-off.
`candidate.json` é um manifest de pins/pendências, **não um plano executável**.
O helper `complete_plan()` nos testes usa exclusivamente dados sintéticos; nunca
copiar seus IDs/hashes para produção. Nenhuma sessão foi criada ou lida aqui.

## Artefatos separados

- `executor.py`: executor child com `prepare` e `activate`, receipt vinculado a
  parent PID/start, lock FD/inode, invocation nonce/hash, plano/pacote/run e
  receipt prepare exato. Não aceita caminho arbitrário de receipt.
- `supervisor.py`: processo **externo no host MEDIA**, lock contínuo, espera,
  invocação fixa de `executor.py`, timeout/PGID/reaping e continuação pós-child.
- `host.py`: backend Docker local **do host**, argv/paths fechados Moss,
  probes nativos, transformer pinado e verificador de aplicação.
- `common.py`: I/O privado durável, CAS/custódia e processos sem saída raw persistida.
- `continuation.py`: GET capabilities/sessão existente, POST runs idempotente e
  polling até terminal; não cria sessões nem muda outras sessões.
- `candidate.json`, `plan.schema.json`: pins e contrato do plano completo.
- `test_activation.py`: fakes de fronteira, processos locais e mutantes causais.

O hash `common.code_hash()` é SHA-256 do JSON canônico
`{nome: sha256(bytes)}` dos cinco módulos, `candidate.json` e `plan.schema.json`.
A revisão deve vincular **todos os nove arquivos**; README/testes são vinculados
pelo commit/tree e `source.paths`, não pelo digest dos módulos executáveis.

## Transação pretendida, não executada aqui

1. Validar paths/custódia/pacote; criar launcher receipt privado durável e manter
   `runs/sequence.lock` por flock antes de qualquer espera.
2. Validar produtor adapter, política memory-off e GETs da sessão/capabilities;
   CAS de source, arquivos, Compose render, preimage Moss e siblings; gate de ingresso.
3. Esperar bounded idle **antes do drain**, sem subtrair turno/stream autorizador.
   Exigir dois snapshots frescos e avançando, separados por 1–3 segundos.
4. Criar marker nativo em stage, persistir receipt dev/inode/SHA **antes** de publicar
   com hardlink exclusivo. Observar estado `draining` posterior ao pedido e repetir
   duas amostras claras; não cancelar trabalho in-flight.
5. Repetir CAS completo depois do drain. Sob o mesmo lock, child `prepare`, validar
   receipt exato, repetir CAS e child `activate`. O child refaz observação e CAS.
6. Aplicar somente config e override image-only. Derivar config com `transform()`
   aprovada, puro em memória no Python já instalado do container, sem seu `apply()`.
   Pin obrigatório de `configure.py`:
   `3cc5c8930ac6894dbad28969f8786f08566a0d9833afbf3e7fa5ee2120018a33`.
   Seu conteúdo não vem de um comando arbitrário do caller.
   Rejeitar aliases/anchors/keys duplicadas em YAML. Preservar inode/uid/mode da
   config/override; gravar com fsync e readback SHA. Não materializar config com creds
   em Git, manifest, receipt, stdout ou log.
7. Confirmar source/files e que o render só troca `services.moss.image`; invocar
   exatamente `docker compose --project-directory /mnt/user/appdata/the-ai-crowd
   -f /mnt/user/appdata/the-ai-crowd/compose.yaml
   -f /mnt/user/appdata/the-ai-crowd/deployment-private/moss/moss-image.override.json
   up -d --no-build --no-deps --pull never moss`.
   Nunca build, pull, stop explícito, migrate, alteração de mounts ou rollback.
8. Reconciliar **sucessor pela imagem candidata e invariants**, não por ID/start antigo.
   Verificar source/config/render/siblings, bytes instalados, identidade/config MCP,
   bridge desabilitado e catálogo oficial por stdio SDK, incluindo rejeição de
   contexto ausente. Reap do child e grupo host antes do callback.
9. Limpar exclusivamente marker próprio por dev/inode/SHA. Callback memory-off na
   sessão exata do plano, com Idempotency-Key/payload digest duráveis. `SUBMITTED`
   não é `COMPLETED`; exigir GET run terminal `completed` da mesma sessão.

Contadores não são somados nem declarados equivalentes: WebUI `active_runs` e
`active_streams`, API total **`api_server.active_runs`**, background `active_api_runs`,
`process_completions`, `active_delegations` e gateway `active_agents`. Ausente,
booleano, negativo, float/string, idade >5s ou snapshot sem avanço falha fechado.
Sem descontar processos/turnos de controle.

## Plano e custódia externos

`plan.schema.json` documenta o formato completo; `Host.validate_plan` faz validação
stdlib mais restrita: caminhos exatos por papel, preimage/image/transformer pinados,
source.paths completo/ordenado dos nove arquivos, nenhum comando arbitrário e
`compose.pre == compose.post`, `transformer.pre == transformer.post`.
`installed` deve coincidir integralmente com `candidate.json`; catálogo exige todos
os nomes únicos da observação completa, contagem derivada e SHA-256 de
`json.dumps(sorted(nomes), sort_keys=True, separators=(',', ':'))`.
A paginação deve terminar em cursor nulo, sem repetição, página vazia ou nomes
vazios; contagem e digest são vinculados ao plano externo, nunca a um valor fixo.
`source.commit/tree` são do commit **final revisado de ativação**, não do base dos pins.
O check scoped de Git é complementado por comparação de cada blob HEAD com arquivo;
`GIT_OPTIONAL_LOCKS=0`, sem trust Git global ou limpeza de dirty state alheio.

Topologia **futura**, que precisa de transporte/revisão próprios e não foi criada:

- host root persistente: `/mnt/user/appdata/the-ai-crowd/deployment-private/moss/tac246-activation`;
- `package/` e `runs/`: owner do supervisor, `0700`; módulos/manifest/schema,
  plano, lock e receipts `0600`; source owner/mode observados explicitamente no plano;
- `source/`: clone independente do commit revisado; não dirty live como build context;
- `inputs/configure.py`: bytes aprovados, custódia declarada no plano;
- `inputs/<nome>.json`: evidências externas privadas `0600`, uid/hash explícitos;
- config host exata: `/mnt/user/appdata/the-ai-crowd/moss/home/profiles/moss/config.yaml`;
- Compose inputs ativos: `/mnt/user/appdata/the-ai-crowd/compose.yaml` e
  `/mnt/user/appdata/the-ai-crowd/deployment-private/moss/moss-image.override.json`.

Rejeita symlinks inclusive em ancestrais, caminhos relativos e ancestrais group/other
writable; não conserta ownership/modes/ACL para continuar. Isto pode revelar um gate
real no host e deve ser reportado, não relaxado. O lock pressupõe exclusividade
cooperativa também para os escritores de config/Compose; não é fence global de
Docker contra administradores não cooperativos.

Evidência externa contém `kind`, `state: VERIFIED`, `observed` epoch (idade <=300s),
`producer` não vazio e os seguintes campos, vinculados pelo SHA exato no plano:

- adapter: `kind: official-adapter-producer`, `image` igual ao adapter pinado,
  `reloaded: true`, `requestContextVerified: true`, `processStart` real não vazio;
- memory: `kind: api-server-memory-off`, `platform: api_server`, `memoryOff: true`,
  `containerImage` igual à imagem Moss candidata.

Estas são **atestação externa do produtor/operador**, não verificação independente
do servidor pelo Moss. O pacote não gera nem preenche essas evidências. Nenhum
campo `memory:false` fictício é enviado à API; a política real AIAgent `api_server`
precisa ter sido verificada externamente. Credencial usa somente `API_SERVER_KEY`
já disponível no ambiente do container; falta de auth bloqueia, sem recuperar
segredos de `/proc` ou reconfigurar credentials.

O host precisa de Linux Python3 stdlib, prctl subreaper/flock/proc, Docker/Compose
já presentes. Os probes usam o Python existente `/opt/hermes/.venv/bin/python`
do Moss, PyYAML e SDK MCP já instalados; sem lazy installs. O supervisor pressupõe
um **lançamento host-owned sobrevivente** revisado separadamente. Não inclui um
instalador nohup/setsid/service/cron e não prova sobrevivência de um launch real.

## Verificação local reproduzível (sem efeitos externos)

No candidato isolado:

```sh
cd /opt/data/profiles/moss/runtime/execution-candidates/tac246-activation/ops/official-paperclip/activation
python3 -B -m unittest -v test_activation
```

Os testes usam apenas stdlib, filesystem sob `$TMPDIR`, fakes de backend/HTTP e
processos locais. Há mutantes que removem a segunda amostra, CAS pós-prepare,
API total e gate de reap; cada um precisa falhar no oracle comportamental nomeado.
Não executar `supervisor.py PLAN` nesta tarefa: esse entrypoint é o executor com efeitos.
`--preflight PLAN`, para uma fase futura autorizada no host, só faz leituras/GETs,
não cria lock/receipt/marker; reporta o gate faltante em JSON. Não foi executado aqui.

## Falhas, continuidade e limites de prova

`BLOCKED_PRE_EFFECT`: nenhum child activate foi invocado. Marker staged/publicado
pode ficar retido para reconciliação explícita; não é limpo cegamente em exceções.
`EFFECT_UNCERTAIN`: activate foi invocado e pode ter escrito arquivos/recriado;
nunca inferir ausência de efeito, repetir ou restaurar automaticamente.
`ACTIVATED_CONTINUATION_PENDING`: activate verificado/reaped; callback/clear marker
não fechou. Preservar receipts e reconciliar somente essa fase, não repetir lifecycle.
`COMPLETED`: verificação do executor e run de continuação terminal; não significa
aceite humano, board concluído, review ou promoção dos outros três runtimes.

O executor tem PGID próprio, PID/start/argv SHA/rc e reap duráveis; seus comandos
supervisionados herdam esse PGID. TERM/KILL e reap do grupo pelo supervisor externo
são bounded; cleanup local de comando nunca sinaliza o grupo do próprio executor.
Falha de cleanup não declara `reaped:true`. Stdout/stderr
child são `/dev/null`; probes são capturados só em memória, nunca em receipts/logs;
CLI só emite JSON com estado/digest/gate de allowlist, sem traceback/texto de erro raw.
Matar cliente Docker não prova cancelamento de operação no daemon/container: estado
continua incerto e exige reconciliação externa. SIGKILL/power loss também exigem
reconciliação dos receipts/PIDs/estado, não resume automático.

O verifier de aplicação não se limita a health: verifica bytes/config/identidade,
catálogo oficial e negativa de contexto ausente. **Não prova um turno real Hermes
usando contexto válido do novo produtor nem uma chamada MCP de sucesso em produção**;
esse aceite integrado permanece gate externo após ativação autorizada. Fixtures
já exercitadas nas imagens são evidência separada, não produção inventada.
Não há smoke de inferência/modelo, POST real, alteração de sessões alheias,
identidades/wakes/permissions/budgets/memory/channels/hiring, adapter instructions,
TAC236 binds/ACL (gate negativo preservado), TAC262 ou source canônica.
