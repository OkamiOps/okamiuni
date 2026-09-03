# Assistente de IA e Dashboard — desenho

Data: 2026-09-01. Estado: aprovado em conversa, aguardando leitura do dono.

Esta spec cobre quatro sub-projetos que compartilham a mesma arquitetura e
são executados em ordem, cada um com o próprio plano de implementação em
`docs/superpowers/plans/`:

1. **Núcleo do assistente** — corrigir, unificar e dizer a verdade sobre o provedor.
2. **Dashboard "Briefing do dia"** — mockup HTML aprovado antes, depois SwiftUI.
3. **Triagem por IA** — a análise persistida passa a dizer *por que* um email importa.
4. **Agente com ações** — o assistente propõe ações tipadas; nada executa sem clique.

Um sub-projeto só começa quando o anterior está verde (compila, suíte dos quatro pacotes
sem falha nova, capturas conferidas). Linha de base medida em 2026-09-01 sobre `main`
(0a6330a): 4 falhas pré-existentes, nenhuma de IA ou dashboard —
`DatabaseMailSourceTests.swift:57`, `DatabaseBodyFetcherTests.swift:180`,
`GmailMirrorTests.swift:110` (UNISync) e `QuickReplyBandTests.swift:817` (UNIShell).

---

## 0. Diagnóstico que motivou o trabalho

Mapa completo em 2026-09-01, com arquivo e linha na data:

**Workflow de IA**

- Os tipos e a cópia dizem "local" para provedores remotos: `OnDeviceTextAssisting`,
  `OnDeviceAssistantMailContext`, `LocalAssistantPanel`, e textos como "Usa todas as
  caixas e a agenda carregadas neste Mac" (`LocalAssistantPanel.swift:113`) e "Lendo o
  contexto local…" (`:572`) aparecem com Grok, LiteLLM, Codex e CLI selecionados.
- O commit `0a6330a` ("send full hydrated email to configured AI") só passou o `Budget`
  para o contexto de email. `FoundationModelsTextAssistantPrompt.transform` ainda corta o
  texto em 8 000 caracteres (`FoundationModelsTextAssistant.swift:352`) e
  `render(_ workspace:)` (`:429`) ignora o orçamento e fixa 24 emails / 32 eventos.
- Três caminhos de "gerar rascunho"; só o leitor e o composer usam `transform(.draftReply)`.
  Dashboard (`DashboardScreen.swift:739`) e painel (`LocalAssistantPanel.swift:50`) mandam
  pergunta livre por `answer()`, cujo prompt pede Markdown. O rascunho volta com `**` e listas.
- O prompt de `answer()` abre com "Responda à pergunta atual em português do Brasil"
  (`:283`) *depois* da linha de idioma das preferências, que só é emitida quando o idioma não
  é pt-BR. A preferência de idioma nunca vence.
- Timeouts: API/LiteLLM 30 s (`AssistantRouter.swift:38`), CLI 60 s com teto 120 s (`:55`),
  OAuth direto 120 s. O dono já viu o Grok falhar por tempo.
- `LiteLLMOAuthCoordinator` e `AssistantProviderOAuthCoordinator` são `@MainActor`: toda
  chamada remota passa pela thread de interface para ler ou renovar token.
  `AssistantCLIDiscovery().scan()` varre o disco a cada requisição (`AssistantRouter.swift:42`).
- `AssistantRouter.availability()` não tem chamador fora dos testes. `IntelligencePresentation`
  é `.configuredAssistant` fixo em `App/OkamiUNIApp.swift:136` e `:259`; não existe estado
  "não configurado".
- Quatro enums de erro (`OnDeviceTextAssistantError`, `OpenAICompatibleTextAssistantError`,
  `AssistantProviderOAuthTextAssistantError`, `AssistantCLITextAssistantError`) achatadas em
  `localizedDescription` sem ação de recuperação. stderr do CLI vai para `/dev/null`.
- Markdown renderizado só em `ReaderIntelligencePopover` (`ReaderAssistantMarkdown`). Painel
  e dashboard mostram `Text` cru.
- `DashboardScreen.run()` reimplementa a máquina de estado de `LocalAssistantConversation`.
- A análise persistida por mensagem (`MessageIntelligenceCoordinator`) é sempre
  `FoundationModelsMessageAnalyzer` (`AppComposition.swift:148`), independente do provedor.
- Testes: `AssistantRouterTests` não cobre `.cli` nem `.providerOAuth`; nenhum teste do
  assistente no dashboard; nenhum golden do que sai da máquina no contexto de workspace.
- As flags de CLI (`--safe-mode`, `--tools ""`, `--no-chrome`, `codex exec --json`,
  `opencode --pure run --format json`) **foram conferidas nos binários instalados em
  2026-09-01 e existem**. O problema real é o stderr descartado.

**Dashboard**

- Única tela com cartões flutuantes e sombra própria (`DashboardScreen.swift:604-621`),
  raios literais 20/14, títulos em sans, sombra `Color.black.opacity(...)` fora dos tokens.
  O resto do app usa serif no título, `capsLabel` mono nos rótulos e superfícies planas
  separadas por hairline. O protótipo em `design/` não tem tela de dashboard.
- Três `metricTile` verde/laranja/ciano usam `success/accent/info` como decoração;
  "Emails" mostra o tamanho do recorte (≤ 7), não da caixa.
- Metade da tela é o assistente mostrando uma frase; o conteúdo fica em 340–440 pt.
- `DashboardFocus` calcula 7 emails e 8 eventos; a tela mostra 3 e 3.
  `omittedMailCount` e `omittedMeetingCount` nunca são exibidos.
- Prioridade é heurística por tags "Precisa resposta / Lead / Prazo" que só existem nas
  fixtures (`Fixtures.swift:96,127,154,182`). Em conta real quase tudo vira "Média".
- `rankPill` colapsa seis `Reason` em dois rótulos. CTAs duplicados. Robô desenhado com
  `Circle`. Nenhuma ação rápida.
- Os testes atuais não travam pixels: `DashboardScreenTests` só afirma tamanho e a string de
  `briefingQuestion`.

---

## 1. Núcleo do assistente

### 1.1 Nomes

Renomear em todos os pacotes e testes, sem typealias de transição:

| Antes | Depois |
|---|---|
| `OnDeviceTextAssisting` | `TextAssisting` |
| `OnDeviceAssistantMailContext` (+ extensão `+Message`) | `AssistantMailContext` |
| `OnDeviceAssistantConversation` / `OnDeviceAssistantTurn` / `OnDeviceAssistantTurnRole` | `AssistantConversationSnapshot` / `AssistantTurn` / `AssistantTurnRole` |
| `OnDeviceWritingAction` | `WritingAction` |
| `OnDeviceTextAssistantError` | `TextAssistantError` |
| `OnDeviceAssistantBridge` | `AssistantBridge` |
| `LocalAssistantPanel` / `LocalAssistantConversation` / `LocalAssistantMode` / `LocalAssistantSuggestion` | `AssistantPanel` / `AssistantConversation` / `AssistantScope` / `AssistantSuggestion` |
| `OnDeviceMessageAnalyzing` / `OnDeviceMessageAnalysisInput` / `OnDeviceMessageAnalysisResult` / `OnDeviceMessageAnalysisError` | `MessageAnalyzing` / `MessageAnalysisInput` / `MessageAnalysisResult` / `MessageAnalysisError` |
| `OnDeviceMessageAnalysisAvailability` | `AppleIntelligenceAvailability` (é só sobre o Foundation Models) |

`FoundationModelsTextAssistant` e `FoundationModelsMessageAnalyzer` mantêm o nome: são
de fato o motor no dispositivo. `FoundationModelsTextAssistantPrompt` vira
`AssistantPrompt` porque é usado pelos quatro adaptadores.

### 1.2 Cópia

Some toda frase que afirme processamento local sem checar o provedor. No lugar, um único
valor `AssistantDestination` (em `UNISync`, derivado de `AssistantSettings`):

| Provedor | `label` | `detail` |
|---|---|---|
| `.foundationModels` | "Neste Mac" | "Nada sai deste Mac." |
| `.providerOAuth` xAI | "Grok · xAI" | "Sai deste Mac para a xAI." |
| `.providerOAuth` codex | "Codex · ChatGPT" | "Sai deste Mac pelo Codex instalado." |
| `.openAICompatible` | "API · {host}" ou "LiteLLM · {host}" | "Sai deste Mac para {host}." |
| `.cli` | "{Claude Code|Codex CLI|OpenCode} · CLI" | "Sai deste Mac pelo CLI instalado." |

O `label` aparece no cabeçalho do `AssistantPanel`, ao lado do campo do dashboard, no
título do popover do leitor e no rodapé de "Perguntar ao ambiente". O `detail` aparece
no `IntelligencePresentation.detail` e no tooltip.

### 1.3 Uma máquina de estado

`AssistantConversation` (`@MainActor @Observable`, hoje `LocalAssistantConversation`) passa
a ser a única dona de transcript, `isLoading`, `failure`, `task`. `DashboardScreen`,
`AssistantPanel`, `MessageWindow` e o popover do leitor recebem uma instância por
injeção; `DashboardScreen.run/runDraft/runSuggestion` são removidos.

API pública:

```swift
func ask(_ question: String)              // answer()
func draftReply()                         // transform(.draftReply) sobre o contexto de email
func summarize()                          // answer() com pergunta fixa de resumo
func briefing()                           // answer() sobre o workspace, pergunta do §2.5
func cancel()
func clear()
func retry()
```

Regras:

- Toda chamada guarda o `Task` e `cancel()` o cancela; fechar a superfície cancela.
- Histórico enviado ao motor: últimos 16 turnos, em toda superfície.
- `draftReply()` só existe com contexto `.email` ou `.conversation`; com `.workspace`
  o botão não aparece. O resultado é prosa de email e entra no transcript como turno do
  assistente com `kind: .draft`, que a UI renderiza sem Markdown e com "Usar no composer".
- Resposta vazia vira `TextAssistantError.emptyResponse`, uma única cópia.

### 1.4 Orçamento, tempo e prompt

- `AssistantPrompt.transform` recebe `budget` e usa `budget.maximumTextCharacters`
  (novo campo: 8 000 em `.onDevice`, 400 000 em `.configured`) no `<untrusted-text>`.
- `AssistantPrompt.render(_ workspace:budget:)` usa `budget.maximumWorkspaceEmails`
  (24 / 256) e `maximumWorkspaceAgendaItems` (32 / 128).
- `customInstruction` é limitado por `maximumCustomInstructionCharacters = 6_000`.
- Timeout: `AssistantRouter.requestTimeout` padrão 120 s e usado para
  `.openAICompatible`; `cliRequestTimeout` padrão 120 s com faixa 30–300 s;
  `.providerOAuth` mantém `max(requestTimeout, 120)`. `URLSessionConfiguration` desses
  adaptadores recebe `timeoutIntervalForResource = timeout` além de `timeoutIntervalForRequest`.
- `answerInstructions` deixa de conter idioma. `AssistantBehaviorPreferences.generatedInstructions()`
  sempre emite a linha de idioma, inclusive para pt-BR. Teste: preferência `english` produz
  prompt sem a string "português".

### 1.5 Disponibilidade e erros

`AssistantRouter` ganha `assistantAvailability()` (o `availability()` do protocolo `TextAssisting`, que devolve `AppleIntelligenceAvailability` e mora em UNICore, passa a derivar dele):

```swift
enum AssistantAvailability: Sendable, Hashable {
    case ready(AssistantDestination)
    case needsSetup(AssistantDestination, reason: String)      // sem chave, endpoint inválido, CLI não encontrado
    case needsSignIn(AssistantDestination)                     // OAuth sem sessão
    case appleIntelligence(AppleIntelligenceAvailability)      // deviceNotEligible / notEnabled / modelNotReady
}
```

É barata: lê `settingsStore.snapshot()`, consulta presença de credencial (sem
materializar), presença de sessão OAuth (sem renovar) e o cache de CLIs. Não faz rede.

`AppComposition` expõe `assistantAvailability` como `@Observable` recomputado quando
`AssistantSettingsStore` muda (o store passa a publicar `didChange`). `OkamiUNIApp`
traduz para `IntelligencePresentation`, que ganha os casos `needsSetup(detail:)` e
`needsSignIn(provider:)` e perde `.configuredAssistant`. `isAvailable` é `true` só em
`.ready`/`.available`. O botão "Perguntar ao ambiente" desabilitado mostra o motivo e um
link "Abrir Ajustes".

`AssistantFailure` (`UNIShell/Support/AssistantFailure.swift`) traduz qualquer `Error`
para `(message: String, recovery: Recovery?)` com `Recovery` em
`{ retry, openSettings, reconnect(AssistantProviderOAuthKind) }`. Mapeamento único; os
quatro enums de adaptador ficam como estão. `AssistantPanel` e o dashboard renderizam o
mesmo `AssistantFailureBand`.

### 1.6 Executores e CLI

- `LiteLLMOAuthCoordinator` e `AssistantProviderOAuthCoordinator` viram `actor`. A UI de
  Ajustes que hoje os observa como `@MainActor` passa a ler um `@Observable` de estado
  publicado pelo actor (`sessionState`), sem tocar em token.
- `AssistantCLIDiscovery` ganha `CachedAssistantCLIDiscovery` com validade de 60 s e
  `invalidate()` chamado ao salvar Ajustes. O router usa o cache.
- `SystemAssistantCLIProcessExecutor` captura stderr (teto 4 KiB, cauda) e o inclui em
  `AssistantCLITextAssistantError.processFailed(exitCode:stderrTail:)`. A cópia mostra a
  primeira linha do stderr quando existe.
- As flags atuais ficam; o teste que trava o argv continua, com comentário datado
  dizendo contra qual versão de cada CLI foram conferidas.

### 1.7 Markdown

`ReaderAssistantMarkdown` e `ReaderAssistantMarkdownBlock` saem do popover para
`UNIShell/Support/AssistantMarkdown.swift` como `AssistantMarkdown`. Painel, dashboard e
janela de mensagem o usam. Turnos `kind: .draft` não passam por ele.

### 1.8 Análise automática com opt-in

- `AssistantSettings` ganha `automaticAnalysis: AutomaticAnalysisRoute` com casos
  `onDeviceOnly` (padrão) e `configuredProvider`. `currentSchemaVersion` sobe para 5; a
  migração preenche `onDeviceOnly`.
- `RoutedMessageAnalyzer: MessageAnalyzing` escolhe por chamada: `onDeviceOnly` →
  `FoundationModelsMessageAnalyzer`; `configuredProvider` → `TextAssistantMessageAnalyzer`,
  que pede ao `TextAssisting` roteado um JSON `{summary, detectedEvent?, category?}` com
  o mesmo contrato de evidência (data só com trecho literal do texto) e valida com
  `Decodable` estrito. Quando o provedor configurado é `.foundationModels`, as duas rotas
  coincidem.
- `MessageIntelligenceCoordinator.processPending` consulta `analyzer.availability()`;
  para a rota remota isso é `AssistantAvailability` mapeada. Falha de auth ou rede em
  três mensagens seguidas **pausa a fila** com estado `paused(reason)` persistido em
  `analysis_queue_state` (tabela nova de linha única, migração `v15`; `sync_state` é por conta e a fila é global), visível na barra lateral ("Análise pausada: {motivo} · Tentar de novo").
  Nunca cai para o Mac em silêncio.
- Ajustes: toggle "Analisar mensagens novas automaticamente com {label}" dentro do
  cartão do provedor, com a frase "Cada mensagem recebida sai deste Mac para {host}." Só
  aparece para provedores remotos.
- **Ruling 2026-09-03**: provedor remoto configurado de propósito é o consentimento; o
  padrão segue o provedor (`AutomaticAnalysisRoute.default(for:)` — `configuredProvider`
  para remoto/CLI, `onDeviceOnly` para Foundation Models) e o interruptor serve para
  restringir a este Mac. `automaticAnalysisTouchedByUser` guarda a escolha manual: quem
  nunca mexeu é migrado uma vez na carga, com `automaticAnalysisSince` em hoje − 7 dias
  (o acervo inteiro continua sendo trabalho de "Analisar o acervo", que pede
  confirmação); quem mexeu não é migrado. O portão
  `automaticAnalysisCoversMessage` não muda.

### 1.9 Testes do sub-projeto 1

- `AssistantRouterTests`: `.cli` com cada `AssistantCLIKind`; `.providerOAuth` xAI e
  codex (incluindo codex sem binário → `executableNotFound`); timeout 120 s chegando ao
  adaptador; cache de discovery usado uma vez em N chamadas.
- `AssistantPromptTests` (renomeado): `transform` com `.configured` não elide 100 000
  caracteres; workspace com 100 emails renderiza 100 em `.configured` e 24 em `.onDevice`;
  golden do prompt de workspace sobre as fixtures (arquivo em `Tests/Golden/`), que falha
  ao acrescentar campo novo ao contexto.
- `AssistantConversationTests`: `draftReply()` chama `transform(.draftReply)` num
  `TextAssisting` espião; `cancel()` durante `ask` deixa o estado idle sem erro; histórico
  enviado tem 16 turnos com 20 acumulados.
- `DashboardScreenTests`: "Gerar rascunho" no sheet chama `draftReply()`, não `ask()`.
- `AssistantAvailabilityTests`: cada provedor em cada estado de credencial.
- `AssistantFailureTests`: cada enum de adaptador → mensagem e recuperação.
- `RoutedMessageAnalyzerTests` e `MessageIntelligenceCoordinatorTests`: rota por
  configuração; pausa após três falhas de auth; retomada manual.
- `AssistantBehaviorPreferencesTests`: idioma inglês não produz "português".

### 1.10 Registro

Entradas novas em `docs/decisoes-de-engenharia.md`: "Timeout de 30 s era errado para
prompt de 400 mil caracteres", "Sem fallback silencioso de provedor", "Codex por
assinatura roda pelo CLI", "Dado não confiável vai entre delimitadores escapados", "Opt-in
para análise remota e fila que pausa em vez de cair para o Mac".

---

## 2. Dashboard "Briefing do dia"

### 2.1 Processo

1. `design/07-dashboard.html`: arquivo próprio, com o mesmo `<style>` de tokens do
   protótipo (copiado, não linkado — o `.dc.html` de 220 KB não é editado), o mesmo chrome
   de 58 px com abas Dashboard/Caixa/Agenda, 1440×916, e um seletor `data-theme` para
   conferir `okami`, `tinta`, `noite` e `neon`. Estados desenhados: cheio, vazio, com
   briefing gerado, com transcript aberto.
2. O dono aprova o mockup (ou pede ajustes) antes de qualquer Swift.
3. Implementação em SwiftUI contra o mockup, medida no `RenderHarness`; divergência é bug
   com número dos dois lados, como manda o princípio 1 do README.

### 2.2 Layout

Abaixo do chrome, `paper` de fundo, padding 22 como as outras telas:

```
┌ cabeçalho ───────────────────────────────────────────────────────────────┐
│ TERÇA · 1 DE SETEMBRO           (capsLabel)          [Gerar briefing]     │
│ Boa tarde, Marcos               (serif 28 semibold)   Grok · xAI  (ink3)  │
├ faixa de briefing (só quando gerado) ────────────────────────────────────┤
│ texto serif 15 · "Gerar de novo" · ✕                                      │
├ coluna principal ──────────────────────────────┬ hairline ┬ coluna 300 ──┤
│ PRIORIDADES · 7                                │          │ AgendaRail    │
│ ▌ Marina Duarte   Revisão do contrato   09:42  │          │ (reutilizado) │
│    Precisa resposta                            │          │               │
│ ▌ …                                            │          ├──────────────┤
│ + 4 na Caixa →                                 │          │ PENDÊNCIAS    │
│                                                │          │ • …           │
│ ─ transcript (≤ 40 % da altura, só se houver) ─│          │               │
│ [ Pergunte sobre seus emails…        ↑ ]       │          │               │
│ Grok · xAI                                     │          │               │
└────────────────────────────────────────────────┴──────────┴──────────────┘
```

- **Cabeçalho**: data em `capsLabel`, saudação `theme.serif` 28 semibold em `ink`, botão
  "Gerar briefing" no estilo `ChromeButton` com o `AssistantDestination.label` embaixo em
  `ink3` 11. Sem emoji.
- **Faixa de briefing**: fundo `surface2`, hairline `line2` em cima e embaixo, texto do
  modelo em `AssistantMarkdown` com corpo serif 15. Ações "Gerar de novo" e fechar. Estado
  de carregamento: a faixa aparece com "Lendo caixa e agenda…" e o spinner do tema.
- **PRIORIDADES**: rótulo `capsLabel` com a contagem. Linhas flush no idioma do
  `MessageRow`: barra de tinta da conta na borda esquerda, remetente sans 13 semibold,
  assunto `subjectWeight/subjectSize` do tema, hora mono 11 à direita, e abaixo do
  assunto um `TintChip` com o `Reason.label` (as seis razões, cores: `needsReply` e
  `deadline` em `warning`, `lead` em `accent`, `flagged` em `info`, `unread` e `today`
  em `ink3`). Não lida: fundo `surface2`; selecionada: `surface3`. Mostra os 7 do
  `DashboardFocus.mail`; rodapé "+ N na Caixa →" com `omittedMailCount` quando > 0.
  Hover revela três ações à direita, no estilo dos botões do leitor: Responder, Arquivar,
  Depois. Clique na linha abre `DashboardMailSheet` como hoje. Menu de contexto igual ao
  da Caixa (`ContextMenus.messageRow`). Vazio: "Nada pedindo uma decisão." em serif 15 +
  linha explicativa `ink3`, como o "Dia livre" do `AgendaRail`.
- **Coluna direita** (300 pt, fundo `surface`, hairline `line` à esquerda): o
  `AgendaRail` existente, sem alteração; abaixo, `PENDÊNCIAS` em `capsLabel` com os
  `focus.pending` em linhas de 2 linhas (texto + origem em `ink3`), vazio "Nada pendente."
- **Assistente**: `DashboardAskField` mantido, dentro de uma cápsula `btn`/`btnLine` com
  o botão ↑; `AssistantDestination.label` abaixo em `ink3`. Com transcript, um
  `AssistantPanel` em modo `embedded` cresce acima do campo até 40 % da altura da
  coluna, com rolagem interna; "Limpar" some tudo. `briefingQuestion` fica como
  pergunta-sugestão quando o transcript está vazio.

Remover: `metricTile`, robô, `betaBadge`, `footerLink` duplicado, `board`, os
`Spacer(minLength: 0)`, `Color.black.opacity`, raios 20/14, `theme.info.color.opacity(0.55)`.

### 2.3 Dados

`DashboardFocus` não muda de contrato neste sub-projeto. A tela passa a consumir
`mail` inteiro, `omittedMailCount`, `pending`; `meetings` fica com o `AgendaRail`.
`visibleMail`/`visibleMeetings` são removidos.

### 2.4 Ações rápidas

Responder → `onOpenComposer(.reply(messageID))` (mesma rota do leitor). Arquivar →
`ContextCommand.move(messageID:to: .archived)` pela mesma porta da Caixa (fila
transacional, desfazer na barra). Depois → `ContextCommand.move(messageID:to: .later)`.
Após arquivar/depois a linha some com a animação padrão da lista e o
`DashboardFocus` recalcula pela `messagesRevision`.

### 2.5 Briefing

`AssistantConversation.briefing()` envia ao workspace a pergunta fixa:

> "Faça um briefing do meu dia em até 120 palavras: o que exige resposta hoje, os
> compromissos de hoje em ordem, e o que pode esperar. Cite remetentes e horários."

O resultado vive em `AssistantConversation.briefingText: String?` (sessão, não persiste; não pode se chamar `briefing` porque o método já ocupa o nome) e é
independente do transcript. Só dispara por clique.

### 2.6 Testes

- `DashboardScreenTests`: render 1200×820 nos quatro estados (cheio, vazio, briefing,
  transcript) em `okami` e `tinta`; linha de prioridade mostra `Reason.label` correto por
  fixture; "+ N na Caixa" aparece com `omittedMailCount = 4` e some com 0; Arquivar chama
  `ContextCommand.move(.archived)` num espião; Depois chama `.later`; "Gerar briefing"
  chama `briefing()` e não `ask()`; `briefingQuestion` atualizado.
- `DashboardMockupParityTests`: larguras (coluna direita 300, padding 22, altura do
  cabeçalho) medidas no harness e comparadas com os números do mockup, no molde dos
  testes de hairline.

---

## 3. Triagem por IA

### 3.1 Modelo

`MessageAnalysisResult` ganha `triage: MessageTriage?`:

```swift
public struct MessageTriage: Sendable, Hashable, Codable {
    public enum Intent: String, Codable { case lead, request, informational, newsletter, transactional, scheduling }
    public enum Urgency: String, Codable { case high, normal, low }
    public let needsReply: Bool
    public let intent: Intent
    public let urgency: Urgency
    public let deadline: DetectedDeadline?   // { date: Date, evidence: String }
}
```

Regra de evidência igual à do compromisso: `deadline` só persiste se `evidence` é
substring literal do texto analisado; caso contrário é descartado na validação.

### 3.2 Persistência

Migração `v16` em `SyncDatabase` (a `v15` é do sub-projeto 1): coluna `triage TEXT NULL` (JSON) em
`message_intelligence`, mais `triage_needs_reply INTEGER` e `triage_deadline_at REAL`
desnormalizados para ordenação. `MessageIntelligenceStore` lê e escreve os três.
`MailItem` ganha `triage: MessageTriage?` hidratado no `LEFT JOIN` já existente
(`MessageIntelligenceStore.swift:77`).

### 3.3 Motores

- Foundation Models: `MessageAnalysisGeneratedOutput` ganha os campos via `@Generable`.
- `TextAssistantMessageAnalyzer`: o JSON pedido ganha `triage`.
- `modelVersion` de ambos sobe; registros antigos sem `triage` são reprocessados pela
  fila quando o corpo estiver disponível, com o mesmo `prioritize(messageID:)`.

### 3.4 Ranking

`DashboardFocus.rank`: quando `item.triage` existe, `needsReply` +100, `intent == .lead`
+80, `deadline` +70 se ≤ 24 h, +50 se ≤ 72 h, +30 depois; `urgency == .high` +20;
`intent` em `{newsletter, transactional}` sem flag é descartado. Sem `triage`, as
heurísticas atuais por tag continuam. `Reason` não muda de casos; a origem (triagem ou
tag) não é exibida.

### 3.5 Superfícies

- Chip do dashboard já mostra a razão (§2.2).
- Faixa TL;DR do leitor ganha, depois do resumo, "Precisa resposta" e "Prazo: qui 15h"
  quando existirem, no mesmo mono/caps.

### 3.6 Testes

`MessageTriageTests` (evidência literal obrigatória), `DashboardFocusTests` (ordem com
triagem presente vence a ordem por tag; newsletter com flag entra), migração `v15`
round-trip, golden do JSON pedido ao provedor remoto.

---

## 4. Agente com ações

### 4.1 Contrato

```swift
public enum AssistantAction: Sendable, Hashable, Codable {
    case archive(messageID: String)
    case moveToLater(messageID: String)
    case moveToToday(messageID: String)
    case markRead(messageID: String)
    case flag(messageID: String)
    case reply(messageID: String, draft: String)
    case addToAgenda(messageID: String)          // usa o DetectedEvent persistido
    case openMessage(messageID: String)
}

public struct AssistantProposal: Sendable, Hashable {
    public let title: String                       // "Arquivar 5 newsletters"
    public let actions: [AssistantAction]
    public let rationale: String
}
```

Allowlist fechada. Não existe enviar, apagar, apagar para sempre, esvaziar lixeira, mover
para pasta arbitrária, nem RSVP.

### 4.2 Saída do modelo

- Foundation Models: `answer()` ganha variante `answerWithProposals()` com `@Generable
  AssistantReply { text: String; proposals: [AssistantProposalOutput] }`.
- Remoto/CLI: o prompt pede, ao final da resposta, um único bloco
  ```` ```okami-actions ```` com JSON `{proposals: [...]}`. O parser extrai o bloco, o
  remove do texto exibido e decodifica com `Decodable` estrito. Bloco ausente ou inválido
  = sem propostas, sem erro.
- Validação em `AssistantProposalValidator`: todo `messageID` precisa estar no
  `AssistantMailContext` enviado naquela chamada; `addToAgenda` exige `DetectedEvent`
  persistido; `reply.draft` passa pelo mesmo `FoundationModelsTextAssistantValidation.response`.
  Proposta com qualquer ação inválida é descartada inteira.

### 4.3 Interface

Propostas rendem como `AssistantProposalCard` abaixo do turno: título serif 14,
lista das ações em sans 12 com o assunto do email resolvido pelo store, botões
"Executar" e "Ignorar". Executar aplica cada ação pelo `ContextCommand` correspondente
(mesma fila transacional e desfazer); `reply` abre o composer via `ComposerSeed` com o
rascunho e **não envia**; `openMessage` abre a leitura. Depois de executar, o cartão vira
"Feito · Desfazer" enquanto o desfazer da barra existir.

Superfícies: campo do dashboard, `AssistantPanel`, `MessageWindow`. O briefing (§2.5)
passa a usar `answerWithProposals()` e mostra até 3 propostas abaixo da faixa.

### 4.4 Testes

Parser do bloco (presente, ausente, malformado, dois blocos → só o último), validador
(ID fora do contexto descarta a proposta inteira; `addToAgenda` sem evento descarta),
execução chama o `ContextCommand` certo num espião e nunca `MailSendPort`, `reply` abre
o composer com o rascunho e o `To` do remetente, golden do prompt com a instrução do
bloco.

---

## 5. Fora de escopo

Streaming de resposta; fallback automático entre provedores; IA disparando sozinha
(além da análise automática já existente, que continua opt-in para remoto); ações de
envio; recorrência; CalDAV.

## 6. Execução

| Sub-projeto | Implementa | Testes | Revisão |
|---|---|---|---|
| 1 Núcleo | `worker-opus` | `worker-sonnet` | orquestrador |
| 2 Dashboard (mockup e SwiftUI) | `worker-fable` | `worker-sonnet` | dono aprova o mockup; orquestrador revisa o Swift |
| 3 Triagem | `worker-opus` | `worker-sonnet` | orquestrador |
| 4 Agente | `worker-opus` | `worker-sonnet` | orquestrador |

Cada sub-projeto: plano próprio via `writing-plans`, branch a partir de
`claude/ai-workflow-dashboard-redesign-1e2d9c`, TDD como manda o README ("teste que passa
com o código quebrado é defeito"), `xcodebuild test` dos quatro pacotes verde antes de
seguir.
