# Marco 2 — Contas de verdade: OAuth Google, IMAP, Keychain e o banco local

Aprovado em 2026-08-28. Decisões tomadas com o dono do projeto:
OAuth **só Google** por ora (Microsoft Graph fora de escopo); IMAP cobre todo
o resto; cache local em **SQLite via GRDB**; cliente IMAP sobre
**swift-nio-imap**; arquitetura **local-first** (o banco é a fonte da verdade
da UI). O Marco 3 (sync incremental, fila de saída, envio, espelho de
triagem) tem spec própria; este marco termina com o app **mostrando o email
real** das contas conectadas.

## Objetivo

Sair das fixtures: o usuário conecta qualquer conta (Google por OAuth, o
resto por IMAP com senha de app), os segredos vivem no Keychain, a carga
inicial de leitura desce para um banco GRDB, e o shell do Marco 1 passa a ler
desse banco — sem mudar de forma.

## Restrições herdadas (valem verbatim)

- **Nada limita provedor, domínio ou número de contas.** `Account.Provider`
  continua aberto; `imap` é o caso geral.
- Swift 6.3, `SWIFT_STRICT_CONCURRENCY: complete`, macOS 26. Swift Testing,
  nunca XCTest. Lógica pura fora de `View`.
- Nenhum controle mudo; erro nunca engolido (`try?` em caminho de rede é
  defeito).
- Fuso não atravessa o modelo: minuto-do-dia + deslocamento de dias; `Date`
  só nas bordas.
- Teste novo só conta provado vermelho com o defeito reintroduzido.
- UI nova provada por ensaio no app real quando envolver interação
  (instrumentos `--ensaiar-*`).

## Dependências novas (as únicas)

| Pacote | Para quê |
|---|---|
| `GRDB.swift` | SQLite: cache de mensagens, FTS5, `ValueObservation` |
| `swift-nio-imap` (+ SwiftNIO que ele traz) | Parser/protocolo IMAP |

Nenhuma outra. OAuth é `ASWebAuthenticationSession` + `URLSession`, ambos do
sistema. Keychain é `Security.framework`.

## Arquitetura

Pacote novo **`Packages/UNISync`**, entre o `UNICore` e o mundo:

```
App ──▶ UNIShell ──▶ UNICore  ◀── UNISync ──▶ (Keychain · GRDB · Gmail API · IMAP)
```

- `UNISync` **importa** `UNICore` (os tipos `Account`, `Message`,
  `TriageBucket` são a moeda) e **não importa SwiftUI**.
- `UNIShell` só conhece `UNISync` pelas portas: `MailSource` (leitura) e um
  novo `AccountDirector` (gestão de contas). O `MailStore` continua a única
  porta da UI.
- O banco é a fonte da verdade: a UI nunca espera rede.

### Componentes de `UNISync`

| Componente | Papel |
|---|---|
| `SyncDatabase` | Abertura/migração GRDB, `DatabasePool`, observações |
| `SecretStore` | Keychain: guardar/ler/apagar segredo por conta (protocolo + implementação real + fake em memória para teste) |
| `GoogleAuth` | PKCE, troca de código, refresh de token, revogação |
| `ProviderDetector` | endereço → rota (`.google` \| `.imap(preset)`) — puro |
| `ImapPresets` | tabela de provedores conhecidos (iCloud, Zoho, Hostinger, Fastmail, …) — pura, aberta, com entrada manual sempre possível |
| `ImapSession` | sessão sobre swift-nio-imap: conectar, autenticar, listar pastas, baixar envelopes e corpos |
| `GmailClient` | `URLSession` tipado sobre a Gmail API: profile, labels, `messages.list/get` |
| `AccountDirector` | ator: adicionar/testar/remover conta, disparar carga inicial, publicar estado por conta |
| `InitialLoader` | carga inicial de leitura (90 dias) para o banco, por conta |
| `DatabaseMailSource` | implementa `MailSource` lendo do banco (substitui as fixtures quando há conta) |

## O banco (GRDB)

Arquivo em `Application Support/OkamiUNI/mail.sqlite` (dentro do contêiner do
sandbox). Migrações versionadas desde a v1.

Tabelas da v1 (o Marco 3 acrescenta as dele):

- `account` — id, endereço, nome de exibição, provedor, host/porta IMAP,
  cor/tint, estado (`ativa`, `erroDeAutenticacao`, `carregando`), datas.
  **Sem segredo nenhum** — segredo é Keychain.
- `folder` — por conta: id do servidor, papel (`inbox`, `archive`, `trash`,
  `sent`, `depois`, `outra`), nome.
- `message` — id nosso, conta, id do servidor (Gmail id / IMAP UID +
  UIDVALIDITY da pasta), remetente, destinatários (`to`/`cc` em JSON),
  assunto, prévia, data recebida (epoch UTC), flags (lida, sinalizada),
  `bucket` (a projeção de triagem), pasta.
- `message_body` — corpo por mensagem (texto em parágrafos, como
  `Message.body` hoje) + **FTS5** externa sincronizada por trigger, com
  tokenizer `unicode61 remove_diacritics 2` — a dobra de acento da busca
  desce para o banco.
- `agenda_item` — o que o "Colocar na agenda" cria passa a persistir
  (campos de `AgendaItem`, incluindo `dayOffset`).
- `sync_state` — por conta: `historyId` (Gmail), `uidvalidity`/`highestUid`
  por pasta (IMAP), carimbo da última sincronização. (Criada já na v1;
  usada de verdade no Marco 3.)

A UI lê por `ValueObservation` → `AsyncSequence`; o `MailStore` ganha um
`load()` que assina em vez de puxar uma vez. Sem conta conectada, o app
continua nas fixtures — os ensaios e capturas não mudam.

## OAuth Google

- **Pré-requisito do dono do projeto** (primeira tarefa do plano, com roteiro
  passo a passo): criar o projeto no Google Cloud Console, ativar a Gmail
  API, configurar a tela de consentimento (app em modo teste serve) e criar
  um **OAuth Client ID de app desktop**. O client ID entra no app por
  configuração (`Info.plist`/xcconfig), não hardcoded.
- Fluxo: `ASWebAuthenticationSession` com **PKCE (S256)** e redirect de
  esquema próprio `com.okamiops.okamiuni:/oauth`; troca de código e refresh
  por `URLSession` direto no endpoint de token (sem SDK do Google).
- Escopos: `gmail.modify` (ler + mudar flags/labels — já cobre o Marco 3),
  `gmail.send` (pedido junto, para não reconsentir no Marco 3),
  `userinfo.email` (identificar a conta).
- Tokens no Keychain (`kSecClassGenericPassword`, serviço
  `com.okamiops.okamiuni`, conta = id da conta). Refresh transparente com
  uma única corrida por conta; falha de refresh marca a conta
  `erroDeAutenticacao` e a UI oferece reconectar — nunca um erro mudo.

## IMAP

- Sessão sobre swift-nio-imap: `LOGIN` (senha de app) sobre TLS implícito
  (993) ou STARTTLS conforme o preset; `LIST`/`SELECT`; envelopes por
  `FETCH` em lotes; corpo por demanda com cache no banco.
- Detecção de papel das pastas por `SPECIAL-USE` quando o servidor dá, senão
  por nome (tabela pura, testável).
- `ProviderDetector`: domínio google → OAuth; senão preset conhecido; senão
  formulário manual (host, porta, TLS). Consulta de MX **não** entra na v1
  (rede no caminho de digitação é latência; a tabela + manual cobre).

## A janela de Contas

Cena nova (`UNIWindow.accounts`), aberta pelo menu do app e pelo item
"Contas…" no menu de contexto da lateral. No idioma do design (tokens, 26
temas, hairlines 1×):

- Lista: cada conta com endereço, provedor, estado (sincronizada às HH:MM ·
  carregando · erro com causa), contador de mensagens no banco; botão
  remover com confirmação (apaga banco da conta + Keychain).
- Adicionar: campo de endereço → rota detectada → OAuth abre o navegador OU
  formulário IMAP (endereço, senha de app com link "o que é isto?", host,
  porta pré-preenchidos) → **Testar e adicionar** com o resultado do teste
  explicado (autenticação ✗, rede ✗, TLS ✗ — mensagens distintas).
- Enquanto a carga inicial roda: progresso por conta na própria janela e na
  linha da conta na lateral.

## Carga inicial de leitura

- **Gmail**: `messages.list` (`newer_than:90d`) paginado + `messages.get`
  (formato `metadata` para a lista, corpo `full` das 50 mais recentes;
  restantes por demanda) + `labels.list`; guarda `historyId` do profile para
  o Marco 3 começar incremental.
- **IMAP**: `SELECT` das pastas com papel, `UID SEARCH SINCE` 90 dias,
  envelopes em lotes de 200; corpos das 50 mais recentes por pasta, resto
  por demanda.
- Projeção para `TriageBucket` na entrada (pura, testada): inbox → `today`,
  pasta/label `OkamiUNI/Depois` → `later` (se existir de instalação
  anterior), Archive/All Mail → `archived`, Trash → `trash`, Sent fica fora
  da triagem (v1 não mostra Enviadas; Marco 3 traz junto com o envio).
- Interrompível e retomável: parar no meio não corrompe (transações por
  lote); reabrir continua de onde parou.

## O que muda nos pacotes existentes

- `UNICore`: `Account` ganha os campos reais (host/porta/tls opcional para
  IMAP, estado, última sincronização); `Message` ganha ids de servidor
  opacos opcionais. Fixtures continuam válidas (campos novos com default).
- `UNIShell`: janela de Contas; linha da conta na lateral mostra estado;
  `InboxScreen` passa a receber a fonte real quando existe conta.
- `App`: composição — abrir banco, montar `AccountDirector`, escolher
  `DatabaseMailSource` vs fixtures.

## Erros

Tipo único `SyncError` com casos distintos (rede, TLS, autenticação,
autorização revogada, quota, servidor) e mensagem em português para cada um.
Toda superfície que mostra uma conta mostra o erro dela com uma ação
(reconectar, tentar de novo). Log estruturado por conta (os `logger` do
sistema, categoria por componente).

## Testes

- `SecretStore` fake em memória; testes do real ficam atrás de uma marca
  local (Keychain em CI é hostil).
- `GoogleAuth` contra um servidor de token **local** (`URLProtocol` stub):
  troca, refresh, refresh falhado, corrida de refresh única.
- `ImapSession` contra um **servidor IMAP falso em memória** sobre NIO
  (scripts de resposta por teste): login ok/falha, lista, fetch em lote,
  UIDVALIDITY trocada.
- `GmailClient` contra respostas gravadas (fixtures JSON reais da API).
- Banco: migração v1, FTS com acento ("Revisao" acha "Revisão" no corpo),
  observação dispara na escrita, projeção de triagem nas fronteiras.
- `ProviderDetector`/`ImapPresets`/detecção de papel: puros, fronteiras.
- UI de contas: ensaio no app real (`--ensaiar-contas`) com um IMAP falso
  local — fluxo adicionar → testar → carregar sem rede externa.
- **Nenhum teste toca rede externa.** Uma conta real só é usada manualmente
  pelo dono do projeto.

## Fora de escopo (registrado)

Microsoft Graph; envio; sync incremental e fila de saída (Marco 3); espelho
de triagem no servidor (Marco 3 — aqui só se **lê** a pasta `OkamiUNI/Depois`
se ela existir); threads/conversas; assinatura por conta sincronizada;
consulta MX na detecção.

## Critério de aceite do marco

Com uma conta Google e uma conta IMAP de qualquer provedor conectadas: o app
abre **offline** mostrando as mensagens dos últimos 90 dias das duas, com
busca (inclusive corpo, com acento dobrado), filtro por conta alcançando
lista e agenda, e a janela de Contas relatando estado e erro com ação. As
fixtures continuam servindo o app sem conta nenhuma.
