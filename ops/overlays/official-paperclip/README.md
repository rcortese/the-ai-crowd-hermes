# TAC-246 — forward-port split Hermes → MCP nativo

## Estado e fronteira

**Candidato de implementação, não revisão nem autorização de produção.** Nenhum
build Docker, push, promoção, restart, configuração de persona ou escrita no
Paperclip real foi executado. A revisão da fonte monolítica
`bd55bc0c527539f18beee35835cbdd1a978db92f` é referência de comportamento;
**não aprova estes bytes split**. A revisão independente posterior permanece pendente.

Esta pasta pertence ao clone independente `tac246-hermes-overlay` de
`the-ai-crowd-hermes`, base `398aa6ca477831ca3695f89b79c8486f4ab015e9`.
Os dois commits de implementação estão em clones independentes de `hermes-agent`:

| Variante | Baseline | Commit fonte | Tree |
|---|---|---|---|
| Moss | `e8cebcaf7c83780ee2d52e19ad8b8850ed6193e9` | `00804cc8eb12e9bae6807c5da4a7ea7d0080c553` | `3c5c184a2e70e14f26e8e0f8b13fb3cfce7b2d35` |
| non-Moss | `2dfcdbfe4ef79cef7ec4c40783d56561f8518849` | `c3a645452d6cae7b613f8b664311ed234c7816c0` | `417eb88358f45f738b65d3ec6c7846d164fa6eab` |

Roots: `/opt/data/profiles/moss/runtime/execution-candidates/tac246-hermes-source-moss`
e `.../tac246-hermes-source-non-moss`. Nenhuma `main` foi avançada.
Os objetos do clone canônico eram parciais: foram copiados apenas para os clones
independentes e os blobs faltantes recuperados pelo promisor nesses clones.
Não houve reparo/mutação da fonte canônica.

## Delta mínimo e preservação

- Autenticação existente antes do parse; validação de objetos, JSON finito e
  limite de 16 KiB UTF-8 (`json.dumps`, `ensure_ascii=False`, separadores padrão).
- `metadata.mcp` → snapshot `ContextVar`, captura explícita antes dos workers
  `_run_agent` e `_RunLaunch`, scope/reset em ambos os executores.
- Captura no handler nativo antes do loop MCP; `ClientSession.call_tool(meta=...)`
  produz `params._meta` separado de `arguments`. Kwargs/modelo não concedem autoridade.
- Sem env fallback, cache de autoridade por sessão, prompt ou histórico.
- SDK 2 continua com rendering/result fields nativos. Não há objeto de resultado
  fabricado para acomodar o teste antigo do SDK 1.
- `api_server_openai_routes.py` não muda: seus caminhos streaming/non-streaming
  já convergem no executor coberto; seu hash é gate de identidade do overlay.
- Preservados `_hermes_version` de cada baseline e o gate recente exclusivo de
  Moss que aceita ID explícito novo sem row. **Não** foi feito upgrade incidental
  dessa semântica na base non-Moss.
- Novo sibling `api_server_mcp_metadata.py` contém apenas a validação do transporte;
  não é plugin, bridge, framework ou serviço novo.

`manifest.json` contém commits/trees, hashes dos patches, pre/post SHA-256 e
modes de todos os arquivos fonte alterados. `files` delimita o overlay executável;
`source_files` inclui também teste e documentação. Não há snapshot runtime no Git.

## Artefatos e recipe de build (não executada)

- `runtime-moss.patch`, `runtime-non-moss.patch`: somente cinco arquivos Python
  necessários ao runtime, gerados dos commits fonte com índices completos.
- `source-moss.patch`, `source-non-moss.patch`: transporte dos sete arquivos dos
  commits fonte, incluindo testes e doc técnica.
- `apply.py`: exige variante explícita, todos os preimages/modes corretos e novo
  sibling ausente; rejeita symlink, patch alterado, drift e reaplicação. Executa
  `git apply --check`, aplica, verifica todos os postimages e compila em memória.
- `Dockerfile`: recipe isolada usando a raiz de `the-ai-crowd-hermes` como build
  context. Exige `HERMES_BASE_IMAGE` imutável e `HERMES_METADATA_VARIANT=moss` ou
  `non-moss`; não escolhe/reconstrói bases, não instala dependências e não muda
  Dockerfiles/Compose das personas. A integração/build real pertence ao pai.

Somente em um estágio de build posteriormente autorizado:

```sh
/opt/hermes/.venv/bin/python /opt/build-overlays/official-paperclip/apply.py \
  --target /opt/hermes --variant "$HERMES_METADATA_VARIANT"
```

Não executar esse comando contra runtime vivo. Preimage mismatch exige nova
análise; não atualizar hashes ou aplicar patch com fuzz como substituto de review.

## Validação reproduzível

Python de teste isolado usado:
`/opt/data/profiles/moss/cache/scratch/tac246-hermes-overlay/venv/bin/python`.
Ele usa Python 3.14.7 e site-packages instalados somente leitura via `.pth`;
pytest 8.4.2 e pytest-asyncio 1.2.0 foram instalados **somente nesse venv scratch**.
MCP SDK exercitado: 2.0.0. Não houve instalação em `/opt/hermes/.venv`.

A partir de cada clone fonte, com HOME de teste isolado:

```sh
export HERMES_PYTHON=/opt/data/profiles/moss/cache/scratch/tac246-hermes-overlay/venv/bin/python
export HOME=/opt/data/profiles/moss/cache/scratch/tac246-hermes-overlay/test-home
export HERMES_TEST_FILE_RETRIES=0
bash scripts/run_tests.sh \
  tests/gateway/test_api_mcp_metadata.py \
  tests/gateway/test_api_server.py tests/gateway/test_api_server_runs.py \
  tests/gateway/test_api_server_active_work_drain.py \
  tests/gateway/test_api_server_turn_boundary.py \
  tests/tools/test_mcp_death_supervisor.py tests/tools/test_mcp_circuit_breaker.py \
  --tb=short -j 2
```

Resultados finais contra commits exatos:
- Moss: **269 passed, 0 failed**, sete arquivos.
- non-Moss: **266 passed, 3 failed**. Os três casos abaixo também falharam no
  export intacto de `2dfcdbfe...`, sem este forward-port, por ID explícito inexistente
  retornar 404. Não foram corrigidos/ocultados nesta entrega:
  - `TestStartRun::test_start_binds_chat_id_for_delegation_wake_target`
  - `TestRunStatus::test_status_reflects_explicit_session_id`
  - `TestRunEvents::test_approval_resolve_all_is_scoped_to_target_run`
- Os **15 testes novos** passam nas duas variantes. Cobrem os endpoints runs,
  chat/completions, responses e native session chat, SSE/non-SSE, concorrência,
  sucessor/ausência, deep-copy, reset após falha no mesmo worker, `_meta` SDK,
  tamanho exato, Unicode inválido e números não finitos.
- RED antes da implementação: os quatro caminhos chat/responses SSE/non-SSE
  chegaram ao SDK, mas falharam por `KeyError: '_meta'`.
- O runner canônico usa `/var/tmp/hermes-pytest-<uid>` para temporários, ignorando
  TMPDIR herdado; ele limpa os roots por tentativa. Não foi alterado por esta tarefa.
  Exportações e probes próprios ficaram no scratch declarado.

A partir do clone overlay:

```sh
P=/opt/data/profiles/moss/cache/scratch/tac246-hermes-overlay/venv/bin/python
R=/opt/data/profiles/moss/runtime/execution-candidates
S=/opt/data/profiles/moss/cache/scratch/tac246-hermes-overlay
"$P" ops/overlays/official-paperclip/tests/test_overlay.py \
  --source-moss "$R/tac246-hermes-source-moss" \
  --source-non-moss "$R/tac246-hermes-source-non-moss" --scratch "$S"
```

Resultado: **16 casos passaram**: aplicação/reversibilidade, patch fonte completo,
drift de bytes/mode, arquivo novo já presente, variante errada, symlink e patch
alterado. Falhas de preflight foram verificadas sem alteração de arquivos.

Composição real, repetir com `VARIANT=moss` e `VARIANT=non-moss`:

```sh
VARIANT=moss
R=/opt/data/profiles/moss/runtime/execution-candidates
S=/opt/data/profiles/moss/cache/scratch/tac246-hermes-overlay
env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$S/test-home" TMPDIR="$S" \
  PYTHONDONTWRITEBYTECODE=1 HERMES_DISABLE_LAZY_INSTALLS=1 \
  PYTHONPATH="$R/tac246-hermes-source-$VARIANT" \
  HERMES_CONTEXT_CANDIDATE="$R/tac246-hermes-source-$VARIANT" \
  PAPERCLIP_CONTEXT_CANDIDATE="$R/tac244-paperclip-context" \
  "$S/venv/bin/python" ops/overlays/official-paperclip/tests/test_composed_context.py
```

O teste cria/limpa home privado antes dos imports. API→executor→MCP nativo→SDK 2→
stdio Paperclip real→servidor HTTP local: **44 tools observadas, 15 HTTP requests**
por variante, com writes/readback locais de issue/documento/API. Concorrência e
sucessor isolados; contexto ausente/malformado/identidade errada gerou **zero HTTP**.
Inferência é fixture explícita, sem modelo. Child/stdio terminou e cleanup foi
verificado. Warning SQLite WAL→DELETE é do store em memória do teste.
Paperclip existente: commit `0ff581a76449667a1c5a56da1f71d9e899af95ed`, tree
`f1e34f8ff03567533fadea53331ad5ed1d968eba`; dist existente exercitado, não rebuildado.
`verification.json` prende os hashes dos inputs dist e dos logs locais.

## Limites e gates restantes

- Testes locais usam SDK/Python indicados, não execução dentro dos containers de
  todas as personas. A base non-Moss foi conferida read-only via Denholm; não
  implica atestado de runtime/SDK de Jen ou Richmond.
- O transporte é in-process. Handoff a Desktop/live canonical Bot Chat, relay ou
  inference subprocess não carrega esse ContextVar; o comportamento prévio foi
  preservado, não substituído por persistência de autoridade. Não direcionar uma
  operação dependente de metadata a um dono externo dessa forma.
- Hermes valida transporte JSON, não schemas/autorização Paperclip. O servidor
  oficial continua responsável por rejeitar contexto inválido. A fixture demonstra
  essa rejeição no candidato Paperclip usado; não atesta o servidor de produção.
- Não houve suíte global, build de imagem, configuração MCP nas quatro personas,
  teste de inferência real ou promoção. Isso não é aceite de produção.
- Logs completos ficam em `$S/final-moss.log`, `$S/final-non-moss.log` e
  `$S/final-composition-{moss,non-moss}.json`, não em source. Fonte instalada foi
  re-hasheada ao final e continua nos preimages do manifest, em Moss e Denholm.
- Revisão independente deve vincular os dois commits fonte **e** este overlay.
  Push/integração/build/lifecycle ficam com o pai e seus gates próprios.

## Correção F1 da revisão independente

A revisão `REQUEST_CHANGES` identificou que o helper assíncrono `finish()` passava
uma coroutine a um wait-helper síncrono, sem consultar o status. O integrador
reproduziu quatro falhas causais e corrigiu somente o teste nas duas fontes:
Moss `bcbc54719bd55738a5e57ce35acc605ded4ddf2e` (tree
`eb7d4c2323ab535894013ee8efc671432538faf5`) e non-Moss
`4b5fcf4e1d7e53de9b46803d301e206542ee2c89` (tree
`7a86fe2ab79143cd42f18142751bd7931f6a1220`). O loop aguarda GET real, distingue
ativo/completed/failed/cancelled e possui deadline de 10 s. Os 19 testes focados
passaram em cada variante com RuntimeWarning e PytestUnraisableExceptionWarning
tratados como erro. Patches fonte e manifest foram regenerados; todos os hashes
runtime e patches runtime continuam idênticos aos da entrega original.
`verification.json` e as contagens da seção anterior são evidências históricas
vinculadas aos candidatos originais, não ao helper corrigido. A revisão final
renovada e a ativação permanecem gates separados; a correção não é autoaprovação.
