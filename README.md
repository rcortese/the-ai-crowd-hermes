# The AI Crowd Hermes

The AI Crowd Hermes é um laboratório público para rodar um pequeno grupo de assistentes especializados sobre Hermes Agent.

A ideia é simples: cada assistente tem uma função clara, um espaço próprio de execução, limites explícitos de autoridade e uma forma padronizada de pedir ajuda, transferir trabalho e devolver resultado para outro assistente ou para o operador.

Este repositório guarda a parte pública e reproduzível desse sistema: contratos, imagens, Compose, exemplos, schemas, políticas e testes. A parte privada — credenciais, memória, histórico, tokens, rotas reais, chaves e detalhes de infraestrutura — fica fora do git público.

## O que este projeto faz

- Define assistentes com responsabilidades diferentes, em vez de um único agente genérico.
- Roda esses assistentes como serviços separados, com homes, workspaces e contratos próprios.
- Usa A2A nativo do Hermes para o edge remoto aprovado Moss→Denholm; consultas entre perfis locais de Moss usam o dispatcher local.
- Usa storage compartilhado apenas para artefatos passivos referenciados.
- Usa testes para validar rotas, permissões, mounts e limites de segurança.
- Separa claramente o que pode ser público do que pertence a uma implantação privada.
- Oferece um ponto de partida prático para evoluir um sistema de assistência pessoal com especialistas colaborando entre si.

## Assistentes modelados aqui

| Assistente | Papel |
|---|---|
| Moss | Operações técnicas, infraestrutura, runtime, incidentes e execução técnica. |
| Jen | Produtividade, tarefas, agenda e fluxos pessoais. |
| Denholm | Produto, coerência entre agentes, decisões e direcionamento. |
| Roy | Assistência pessoal direta para um usuário configurado, com recebimento, organização e encaminhamento prático de pedidos do dia a dia. |
| Richmond | Stewardship de arquivo e organização de materiais. |
| The Elders | Respostas preparadas a partir de pacotes aprovados e escopo restrito. |

Os papéis são intencionais. Quando um assunto pertence a outro assistente, o sistema deve encaminhar com contexto suficiente, em vez de misturar responsabilidades.

## Como a colaboração funciona

O transporte remoto ativo é A2A nativo do Hermes, inicialmente somente Moss→Denholm, com alias e credencial direcionais definidos no runtime. Consultas entre perfis locais de Moss (por exemplo, Moss→reviewer) usam o dispatcher local e não criam uma rota remota. Outros edges remotos permanecem sem transporte até uma decisão e ativação próprias; não há fallback para arquivo, Kanban ou broker. Artefatos grandes podem permanecer no storage compartilhado apenas como dados passivos referenciados.

## Estrutura do repositório

```text
agents/public/          Contratos públicos de cada assistente
agents/private/         Espaços privados ignorados pelo git
runtime/                Homes locais de runtime ignoradas pelo git
schemas/                Schemas JSON para contratos públicos remanescentes
examples/               Exemplos públicos de kanban e review gates
ops/images/             Dockerfiles dos assistentes
ops/manifests/          Inventários de ferramentas e exemplos de capacidade
ops/policies/           Políticas de mounts, capacidades e overlays privados
docs/                   Arquitetura, validação, produção e runbooks
tests/                  Testes públicos e verificações de segurança
compose.yaml            Stack local/base dos serviços
```

## Runtime atual

O `compose.yaml` descreve uma stack com:

- serviços Hermes separados para Moss, Jen, Denholm, Roy, Richmond e The Elders;
- homes de runtime por assistente em `runtime/<assistente>-home`;
- contratos públicos montados como somente leitura;
- workspaces privados montados como leitura/escrita;
- storage compartilhado para artefatos passivos;
- healthchecks por serviço;
- Persona RPC ask-only entre API Servers;
- redes separadas para tráfego interno, proxy privado e LLM local.

Moss também possui uma imagem all-in-one para o runtime operacional, com dashboard, gateway, WebUI e webhook no mesmo serviço. Os outros assistentes rodam com contratos e gateways próprios conforme sua função.

## Comece por aqui

Para entender o projeto:

1. Leia o índice de documentação: `docs/README.md`.
2. Leia a visão de arquitetura: `docs/architecture/system-overview.md`.
3. Leia o modelo de containers: `docs/architecture/agent-container-model.md`.
4. Leia a fronteira público/privado: `docs/architecture/public-private-boundary.md`.
5. Leia os contratos dos assistentes em `agents/public/<assistente>/`.

Para validar a parte pública:

```bash
./tests/run-all.sh
```

Esse comando executa validações de contratos, schemas, exemplos, políticas de mounts, scans contra vazamento de estado privado e renderização básica do Compose. Ele é pensado para ser seguro em um checkout público e não deve exigir credenciais privadas.

## Rodando localmente

Uma implantação real precisa de arquivos privados fora do git público, especialmente em `state/secrets/`, `agents/private/` e `runtime/`.

Fluxo básico esperado em um checkout de implantação:

```bash
docker compose config
docker compose up -d --build moss
docker compose ps
```

Para subir outros assistentes, revise antes os arquivos privados, secrets, variáveis de ambiente, redes externas e políticas de acesso exigidas pela sua instalação.

## Limites importantes

Este repositório não contém e não deve conter:

- credenciais;
- tokens de provedores;
- estado OAuth;
- histórico de sessões;
- memória privada;
- chaves SSH;
- hostnames reais;
- detalhes de rede privada;
- rotas de proxy reais;
- mounts amplos do host;
- Docker socket liberado por padrão.

Ferramenta instalada não é permissão concedida. Uma capacidade só deve ser considerada ativa quando houver configuração privada, credencial, mount, wrapper, política e evidência de validação compatíveis.

## Para quem este repositório é útil

Este projeto é útil para quem quer experimentar uma arquitetura de assistentes pessoais especializados, com coordenação prática entre agentes, limites verificáveis e um caminho limpo entre protótipo público e implantação privada.

Ele não tenta ser um produto fechado. É um scaffold vivo: pequeno o bastante para auditar, explícito o bastante para evoluir e cuidadoso o bastante para não confundir demonstração pública com acesso real a dados privados.
