# Agente interno: ferramentas, MCP, ACP e A2A

A conversa do dashboard, da caixa e da janela de mensagem usa
`WorkspaceAgentAssistant`. O catálogo e a execução das ações pertencem ao
aplicativo, independentemente do modelo escolhido. A análise automática e as
transformações de escrita continuam usando o provedor configurado.

## Capacidades integradas

| Ferramentas | Comportamento |
| --- | --- |
| `accounts_list`, `contacts_search` | Contas autorizadas e endereços observados; não inventam destinatários. |
| `mail_search`, `mail_read_thread` | SQLite completo e busca remota Gmail/IMAP, filtros antes da paginação, hidratação das mensagens encontradas e cobertura remota por conta. |
| `attachment_read` | Texto, PDF com texto, PDF escaneado e imagens com OCR, a partir de IDs de anexos reais. |
| `drafts_list`, `drafts_get` | Rascunhos persistidos, inclusive os criados manualmente, com versão atual. |
| `drafts_create`, `drafts_update` | Rascunhos de texto com idempotência na criação e controle de versão na edição. |
| `drafts_create_html`, `drafts_update_html` | HTML sanitizado pelo parser de MIME do app, mantendo layout, referências CID, assinatura e anexos existentes. |
| `mail_prepare_reply`, `mail_prepare_forward` | Rascunhos ligados à mensagem original; encaminhamentos copiam os anexos disponíveis para o armazenamento do rascunho. |
| `agenda_list`, `agenda_search` | Compromissos das contas permitidas, dados e versão para edição. |
| `agenda_create`, `agenda_update`, `agenda_delete` | Persistência e sincronização pelo mesmo serviço usado pelo app, com idempotência, controle de versão e restauração local se o provider falhar. |
| `mail_propose_action`, `navigation_open` | Cartões de ação e abertura real da mensagem ou rascunho para revisão. |
| `a2a_agents_list`, `a2a_agents_discover`, `a2a_task_delegate` | Descoberta e delegação aos parceiros explicitamente configurados. Só aparecem quando A2A está ativo. |

São 20 ferramentas do aplicativo e três ferramentas A2A opcionais. O agente não
possui ferramenta de envio de email. Salvamentos retornam resultados reais e
cartões para abrir o rascunho. Alterações feitas posteriormente pela pessoa não
são sobrescritas por uma versão antiga.

Ao reabrir no compositor, HTML com tabelas e imagens é apresentado em um bloco
preservado, com introdução editável. O bloco evita que TextKit destrua a estrutura
original; a edição completa desse HTML permanece disponível pelas ferramentas
de rascunho do agente. Rascunhos simples continuam no editor nativo. Anexos
precisam terminar de carregar antes de salvar ou enviar; falhas mantêm a janela
aberta. Imagens de dados só são convertidas para recursos CID na saída MIME.

Busca vazia sem filtros permanece local, salvo `includeRemote: true`.
`includeRemote: false` força SQLite. Falhas de uma conta remota são informadas,
sem transformar cobertura parcial em busca completa. A lista de contatos usa
os endereços observados nas mensagens carregadas.

A extração de anexos é limitada por tamanho e quantidade de texto; PDFs leem
até 25 páginas de texto ou cinco páginas com OCR, e imagens são reduzidas antes
do OCR. O resultado informa truncamento. Arquivos Office não têm extrator nesta
versão. Não há leitura de um caminho ou URL arbitrário passado pelo modelo.

Eventos com convidados exigem o fluxo de confirmação do calendário e não são
alterados diretamente pelo agente, evitando convites e cancelamentos externos
implícitos. O modelo atual de agenda aceita eventos dentro do mesmo dia.
A migração SQLite v22 preserva a identidade e os metadados do calendário.

## Modelos e contratos

Todo `TextAssisting` pode participar do ciclo de ferramentas. Adaptadores
`AgentPlanning` especializados podem preservar as características do provider.
O ciclo padrão limita-se a oito rodadas e quatro chamadas por rodada, valida
argumentos, devolve o schema quando há erro e permite uma reparação de JSON.
Resultados de email e anexos são tratados como dados não confiáveis.

Apple Intelligence usa contexto compacto. Em macOS 26.4 ou posterior, a geração
estruturada recebe primeiro o catálogo de ferramentas e depois o schema exato
da ferramenta escolhida, incluindo argumentos opcionais. Sistemas anteriores
usam o formato tipado compatível com Foundation Models 26.0. Isso compartilha as
capacidades do app, mas não promete a mesma qualidade de raciocínio em todos os
modelos.

Os testes de contrato cobrem OpenAI, Claude, Gemini, Grok, Ollama, modelos
compatíveis e os protocolos CLI Codex, Claude e OpenCode. Esses testes simulam
respostas dos modelos. As provas com modelos reais usam Claude autenticado e
Apple Intelligence, dados fictícios e SQLite temporário; não acessam a caixa
postal da pessoa nem possuem uma porta de envio.

## ACP e MCP

Em **Ajustes → Inteligência**, ative **Usar agente ACP nas conversas**, escolha
um executável compatível e informe argumentos, um por linha. Prefira caminhos
absolutos, inclusive para o script do adaptador. Não há interpretação por shell.
O botão **Testar conexão ACP** executa inicialização e criação da sessão, sem
pedir ao modelo para agir. Salve em **Salvar IA**.

O aplicativo principal permanece com App Sandbox. Um serviço XPC privado,
embutido e assinado separadamente, executa o runtime externo. O serviço tem
acesso normal de um processo local, fora do sandbox: escolha um runtime de
confiança. Ele valida a assinatura do cliente e recebe pedidos limitados; não é
um servidor público. A sessão de login é a do próprio runtime, sem copiar
credenciais para preferências ou pacotes do aplicativo.

Um runtime Node portátil pode ser preparado com
[as instruções de empacotamento](acp-runtime-package.md) e selecionado pelo seu
executável. O pacote não contém login. A compatibilidade depende de um adaptador que implemente ACP v1
e aceite o servidor MCP HTTP fornecido na sessão, não da marca do modelo.

Cada pergunta abre um servidor MCP HTTP em loopback, com porta efêmera e bearer
aleatório. ACP recebe as mesmas ferramentas nativas da conversa. O servidor
valida Host, Origin, bearer, versão e tamanho da requisição. Permissões são
correlacionadas ao `toolCallId`, ao servidor `okamiuni` e à ferramenta anunciada;
somente autorização única é aceita. O cliente reconhece metadados ACP genéricos
e os do adaptador Codex. Não são anunciadas portas de terminal ou filesystem.
Cancelamento, erro e término fecham a sessão e o servidor.

## A2A

Em **Ajustes → Inteligência**, ative A2A e cadastre nome e URL do Agent Card.
Um bearer opcional fica no Keychain; preferências guardam somente sua referência.
Alterar a origem do endpoint remove essa referência. A descoberta não envia o
contexto da caixa postal. A delegação envia somente a tarefa solicitada, sem
incluir automaticamente email, anexos ou histórico.

O cliente implementa os contratos JSON-RPC A2A 1.0 e 0.3: descoberta, mensagem,
tarefa, artefatos, consulta de estado e cancelamento. Não segue redirecionamentos
nem encaminha credenciais entre origens. Respostas e polling têm limites.

Ainda não há servidor parceiro do usuário. A integração é validada contra um
servidor HTTP local independente, inclusive com resposta parcelada acima do
limite e fixtures de versões diferentes. A conexão com um parceiro real depende
de cadastrar seu Agent Card quando ele existir.

## Verificação reproduzível

```sh
swift test --package-path Packages/UNICore
swift test --package-path Packages/UNISync
swift test --package-path Packages/UNIShell --filter 'AgentConnectionsRenderTests|AssistantConversationTests|PainelDoDiaTests|AssistantDrawer|ComposerSendCloseTests'
python3 Tools/audit_localizations.py
python3 Tools/test-package-acp-runtime.py
Tools/ACPExternalRuntimeProbe/build-and-run.sh
```

`LiveUniversalAgentTests` exige `OKAMIUNI_LIVE_UNIVERSAL=1`. Não ative testes
reais automaticamente em CI: dependem de login local, disponibilidade e custo
do provider. Provas do helper ACP usam um bundle de teste separado, assinado,
sem abrir ou reiniciar o aplicativo instalado.

Para substituir o aplicativo instalado, produza um Release limpo e valide
também a assinatura dos componentes embutidos antes da cópia:

```sh
xcodebuild -project OkamiUNI.xcodeproj -scheme OkamiUNI -configuration Release \
  -derivedDataPath build/MailFixesRelease clean build
codesign --verify --deep --strict build/MailFixesRelease/Build/Products/Release/OkamiUNI.app
```

O `build` incremental pode conservar uma assinatura antiga do XPC quando apenas
os recursos de um pacote mudam. A verificação deve falhar antes de substituir
o app; preserve a instalação anterior como backup e não reinicie uma sessão
de composição aberta automaticamente.

Referências de protocolo: [ACP](https://agentclientprotocol.com/protocol/v1/session-setup),
[MCP HTTP](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports),
[A2A](https://a2a-protocol.org/latest/specification/).
