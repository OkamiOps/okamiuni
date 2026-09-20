# Agente interno e conexões ACP/MCP

O assistente interativo usa `WorkspaceAgentAssistant`, que executa ferramentas
nativas sobre o `MailStore`. Perguntas não dependem apenas do snapshot inicial:
o agente pode buscar mensagens paginadas, carregar conversas e criar rascunhos.
A análise automática e as transformações de escrita conservam o provedor atual.

## Capacidades

| Ferramenta | Resultado |
| --- | --- |
| `accounts_list` | Contas permitidas na sessão |
| `mail_search` | Busca local paginada, conta, caixa e período ISO8601 |
| `mail_read_thread` | Corpo carregado sob demanda; até 20 mensagens recentes |
| `contacts_search` | Endereços observados nas mensagens, sem inventar destinatários |
| `drafts_list` / `drafts_get` | Rascunhos persistidos e versão atual |
| `drafts_create` / `drafts_update` | Salvar texto simples, com idempotência e proteção de versão |
| `mail_prepare_reply` | Resposta ou resposta a todos, ligada à mensagem de origem |
| `mail_prepare_forward` | Encaminhamento em texto para revisão, destinatários ainda vazios |
| `agenda_list` | Eventos carregados, datas e horários locais |
| `mail_propose_action` | Cartão para arquivar, mover, sinalizar, marcar lida ou agendar evento detectado |
| `navigation_open` | Abrir mensagem ou compositor do rascunho |

O conteúdo de anexos não é lido por estas ferramentas. Encaminhar arquivos usa
a ação Encaminhar do compositor. Rascunhos HTML não são reescritos pelo agente:
a ferramenta orienta a abrir o compositor, preservando formatação e assinatura.
A busca informa `scope: locallyLoaded`; ela não promete pesquisar mensagens
que ainda não foram sincronizadas. Esta camada não expõe envio nem exclusão.

## Provedor já configurado

A conversa usa um ciclo de no máximo oito rodadas, até quatro chamadas por
rodada. Os adaptadores recebem um plano JSON; o aplicativo valida e executa
cada chamada e devolve o resultado observado. O CLI continua sem ferramentas
próprias: as ações são executadas pelo aplicativo. Chamadas a ferramentas não
passam pelo antigo limite de 2 mil caracteres da pergunta.

Erros, cancelamento e limites encerram a execução. Rascunhos já persistidos
permanecem disponíveis. Cada salvamento produz um cartão para abrir o rascunho.
Alterações de versão recusam sobrescrita de edições posteriores.

## ACP opcional

Em Ajustes → Inteligência, ative **Usar agente ACP nas conversas** e informe o
caminho absoluto de um executável compatível. Argumentos são separados por
linha; não há avaliação de comandos pelo shell. Salve em **Salvar IA**.

Foi validado o adaptador `@agentclientprotocol/codex-acp` **1.12.0**, com um
processo real autenticado, dados fictícios e SQLite temporário. Para instalar
o adaptador em um diretório próprio:

```sh
npm install --prefix /caminho/do/runtime --save-exact @agentclientprotocol/codex-acp@1.12.0
```

Uma configuração que independe do PATH do Finder usa o caminho absoluto do
`node` em Executável ACP e o caminho absoluto de
`node_modules/@agentclientprotocol/codex-acp/dist/index.js` como argumento.
A autenticação é a do agente instalado; o app não copia tokens do Codex.

Cada pedido abre uma sessão ACP v1 e um servidor MCP HTTP em loopback, com
porta efêmera e bearer aleatório. A sessão recebe somente esse endpoint.
O cliente verifica suporte a MCP HTTP antes de enviar a configuração. O
subprocesso recebe ambiente mínimo e um diretório temporário privado.
Não são anunciadas portas de filesystem ou terminal.

Permissões MCP do adaptador Codex são correlacionadas ao `toolCallId` da mesma
sessão, ao servidor `okamiuni`, à ferramenta anunciada e aos metadados do
adaptador. Só `allow_once` é aceito; pedidos genéricos e outros servidores são
recusados. O executável configurado é uma aplicação de confiança da pessoa;
essa correlação não transforma um binário malicioso em um processo seguro.

O servidor valida Host, Origin, bearer, tamanho de requisição e versão MCP.
Não há endpoint público permanente nem token persistido. Cancelar ou encerrar
um pedido fecha a sessão e seu servidor. MCP expõe somente as capacidades
implementadas; não anuncia recursos que ainda não existem.

## Validação

```sh
swift test --package-path Packages/UNICore --filter 'MailAgentToolsTests|AssistantProposalCardTests|DraftStoreTests'
swift test --package-path Packages/UNISync --filter 'AgentConnectionConfigurationTests|WorkspaceAgentAssistantTests|ACPAgentClientTests|LocalMCPServerTests|AssistantSettingsTests|AssistantRouterTests'
swift test --package-path Packages/UNIShell --filter 'AssistantConversationTests|PainelDoDiaTests|AssistantDrawer|SettingsSectionsTests|ComposerSendCloseTests'
python3 Tools/audit_localizations.py
```

`LiveAgentTests` só roda com opt-in explícito:
`OKAMIUNI_LIVE_ACP_NODE` aponta para o Node e `OKAMIUNI_LIVE_ACP_SCRIPT` para o
adaptador. Usa apenas fixtures; não possui porta de envio nem acesso ao banco
de emails da pessoa. Os testes reais cobrem o caminho nativo e ACP → MCP →
rascunho salvo → leitura no SQLite. Esses testes executam fora do App Sandbox.
A execução do adaptador e o acesso à autenticação a partir do aplicativo Release
sandboxed ainda exigem validação na sessão instalada; o teste de protocolo não
comprova essas permissões do macOS.

A2A depende da escolha de um agente parceiro e de uma tarefa concreta; não há
uma integração A2A ativa nesta entrega. Edição completa de eventos e leitura
de conteúdo de anexos também não são capacidades anunciadas nesta versão.

Referências: [ACP](https://agentclientprotocol.com/protocol/v1/session-setup),
[MCP HTTP](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports),
[adaptador Codex](https://github.com/agentclientprotocol/codex-acp).
