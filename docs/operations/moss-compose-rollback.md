# Moss Compose rollback — apresentação pública semântica

## Problema resolvido

O rollback anterior tratava uma implantação como uma simples troca de imagem. Depois de uma mudança estrutural no Docker Compose, isso não era suficiente: o rollback podia restaurar a imagem antiga enquanto mantinha comandos, mounts, redes, healthchecks ou outras propriedades do Compose candidato.

## O que muda

A implantação de Moss passa a ser tratada como uma transação completa, com escopo limitado ao próprio Moss:

1. Antes de qualquer alteração, o sistema sela duas configurações independentes: a candidata e a configuração ativa usada para rollback.
2. Cada configuração é renderizada de forma determinística a partir dos seus próprios arquivos selados. O rollback não consulta nem combina o `compose.yaml` que estiver ativo no momento da recuperação.
3. O deploy unit contém somente Moss e os recursos de Compose diretamente necessários a ele. Jen, Denholm, Roy, Richmond e The Elders permanecem fora da unidade de implantação.
4. Uma operação só é considerada bem-sucedida quando Moss está saudável, a identidade esperada está presente, as cinco personas fora de escopo permanecem invariantes e o teste A2A delimitado passa.
5. Falhas de aplicação, prova ou recuperação produzem estados explícitos; erros de rollback não são ocultados.
6. Operações terminais podem ser removidas automaticamente somente após uma janela de retenção validada e limitada. Operações ativas ou ambíguas nunca são removidas pelo coletor.

Essa separação de escopo significa que o mecanismo verifica a invariância das outras personas; não significa que elas façam parte do artefato aplicado nem que sejam reiniciadas ou reconfiguradas pelo rollback de Moss.

## Segurança operacional

A mudança também separa claramente três etapas que antes podiam se misturar:

- construção da imagem candidata;
- seleção da imagem e preparação da transação;
- autorização de lifecycle em produção.

O pacote público contém código-fonte e testes. Ele não instala o executor, não cria uma autorização, não constrói uma imagem, não reinicia Moss e não altera produção por si só. Publicar o código, portanto, não equivale a ativar a mudança em produção.

## Como foi validado

A validação do candidato inclui:

- a matriz fake-first T01–T87;
- casos causais para rollback estrutural, retenção, invariância das outras personas e prova A2A;
- renderização real somente-leitura do Compose, reduzida semanticamente ao grafo de Moss;
- verificação antes/depois sem lifecycle provocado pelo candidato;
- uma revisão técnica independente do artefato exato, com resultado `APPROVED WITHOUT CHANGES`.

Esses resultados descrevem a validação do candidato e não constituem uma declaração de execução ou aprovação de lifecycle em produção.

## O que permanece fora de escopo

Esta alteração não autoriza publicação, instalação, build, deploy, promoção ou lifecycle. Qualquer ativação futura continua exigindo drenagem e rechecagem de streams, compatibilidade com o estado produtivo atual e aprovação explícita do operador. A autorização para build ou smoke test permanece separada da autorização posterior para lifecycle.

## Documentação pública relacionada

O runbook técnico versionado está em `docs/operations/hddt-moss.md`. Ele documenta comandos, custódia, inputs selados, normalização do grafo, critérios de sucesso e recuperação, retenção automática, validação e gates ainda pendentes.
