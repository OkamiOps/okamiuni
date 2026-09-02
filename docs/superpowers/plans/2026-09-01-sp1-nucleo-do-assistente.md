# Sub-projeto 1 — Núcleo do assistente: plano de implementação

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fazer o assistente do OkamiUNI dizer a verdade sobre o provedor, ter uma única máquina de estado e um único orçamento de prompt, e nunca mandar conteúdo para fora do Mac sem a pessoa ter escolhido isso.

**Architecture:** O contrato puro (`TextAssisting`, `AssistantMailContext`, `AssistantPrompt`) fica em UNICore/UNISync sem prefixo mentiroso; `AssistantRouter` continua a única porta que escolhe adaptador por chamada e passa a publicar `AssistantDestination` e `AssistantAvailability` baratos, sem rede. No shell, `AssistantConversation` (`@MainActor @Observable`) vira a dona única de transcript, `isLoading`, `failure` e `task`, injetada em painel, dashboard, janela de mensagem e popover do leitor; erro de qualquer adaptador atravessa um só tradutor (`AssistantFailure`) e uma só faixa (`AssistantFailureBand`).

**Tech Stack:** Swift 6 strict concurrency, SwiftUI, Swift Testing, GRDB (migração v15 da fila de análise), FoundationModels

**Spec:** docs/superpowers/specs/2026-09-01-ia-e-dashboard-design.md (seções 0 e 1)

---

## Global Constraints

- **Swift Testing, nunca XCTest.** `import Testing`, `@Suite`, `@Test`, `#expect`, `#require`.
- **Teste novo nasce vermelho.** Cada tarefa escreve o teste, roda, vê falhar com a mensagem esperada, e só então implementa. Teste que passa com o código quebrado é defeito (`README.md` → "Como este projeto se testa").
- **Sem typealias de transição nos renames.** A tabela 1.1 é aplicada de uma vez, em todos os pacotes e testes; nada de `typealias OnDeviceTextAssisting = TextAssisting`.
- **Nada de cor, raio ou sombra literal em view nova.** Só tokens do `Theme` (`theme.surface2`, `theme.line2`, `theme.radiusSmall`, `Hairline.thickness(displayScale)`); nada de `Color.black.opacity(...)` nem `cornerRadius: 20`.
- **Timeouts de 120 s.** `AssistantRouter.requestTimeout` padrão 120; `cliRequestTimeout` padrão 120 com faixa 30–300; `.providerOAuth` mantém `max(requestTimeout, 120)`; `URLSessionConfiguration` dos adaptadores recebe `timeoutIntervalForResource` além de `timeoutIntervalForRequest`.
- **`maximumCustomInstructionCharacters = 6_000`** limita `customInstruction` (hoje ele é cortado em 1 200 pelo `maximumHistoryTurnCharacters`).
- **`automaticAnalysis` nasce `.onDeviceOnly`.** A rota remota é opt-in explícito; a fila **pausa** em vez de cair para o Mac em silêncio.
- **A cópia "local" some.** Nenhuma frase pode afirmar processamento local sem consultar `AssistantDestination`. "Nada sai deste Mac." só aparece em `.foundationModels`.
- **Lógica pura fora das views.** Uma `View` SwiftUI é `@MainActor` implícito; `static` de lógica dentro dela trapa em runtime quando um teste nonisolated a chama (`docs/decisoes-de-engenharia.md`).
- **Hairline é `1/displayScale`**, borda é `strokeBorder`.
- **Commits frequentes**, um por tarefa no mínimo, terminando com:
  ```
  Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
  ```
- **Cada tarefa termina compilando e com os testes do pacote tocado verdes.** "Verde" significa sem falha nova. A linha de base medida em 2026-09-01 sobre `main` (0a6330a) já tem 4 falhas que não são deste trabalho e não devem ser "consertadas" de passagem: `DatabaseMailSourceTests.swift:57` ("O corpo vem junto para quem já o tem no banco"), `DatabaseBodyFetcherTests.swift:180`, `GmailMirrorTests.swift:110` ("Arquivar tira a INBOX") em UNISync, e, em UNIShell, `QuickReplyBandTests.swift:817`, `TrashTests.swift:102` ("só a Lixeira e Enviadas têm símbolo"), `ReaderHTMLLoadingTests.swift:62` e `:90` (medidos de novo em 2026-09-02 num checkout limpo de 3d9af34: 7 falhas herdadas no total). Se uma tarefa fizer alguma delas passar ou mudar de mensagem, registre no commit.
- **A suíte de UNIShell rodou inteira no shell do orquestrador em 2026-09-01** (≈135 s, com sandbox). Se travar no seu ambiente, veja a nota de ambiente no fim do plano antes de suspeitar do código.

---

## Comandos de teste conferidos nesta máquina (2026-09-01)

Os quatro pacotes são SwiftPM puros. **Não existe scheme de teste no Xcode** — `project.yml` só monta o alvo do app.

```bash
# suíte inteira de um pacote (o que fecha cada tarefa)
swift test --package-path Packages/UNICore
swift test --package-path Packages/UNISync
swift test --package-path Packages/UNIShell
swift test --package-path Packages/UNIDesign

# um único conjunto (o laço rápido do TDD) — o filtro casa com o nome do tipo
swift test --package-path Packages/UNICore  --filter DashboardFocusTests
swift test --package-path Packages/UNISync  --filter AssistantRouterTests
swift test --package-path Packages/UNIShell --filter DashboardScreenTests

# os quatro de uma vez (o laço do README)
for p in UNICore UNIDesign UNIShell UNISync; do (cd "Packages/$p" && swift test); done
```

Conferido de verdade nesta máquina em 2026-09-01:

- `swift test --package-path Packages/UNICore --filter DashboardFocusTests` → `✔ Test run with 11 tests in 1 suite passed`, 16 s (primeira vez, com compilação).
- `swift test --package-path Packages/UNISync --filter AssistantRouterTests` → `✔ Test run with 4 tests in 1 suite passed`, 5,8 s (incremental).
- `swift test --package-path Packages/UNIShell --filter DashboardScreenTests` → `✔ Test run with 4 tests in 1 suite passed`, 3,5 s. **Só fora de um shell sandboxed** — ver a nota de ambiente no fim deste plano.

A primeira compilação de `Packages/UNIShell` passa de 2 min; rode em segundo plano quando o laço for longo.

O alvo do app não tem testes; ele é só a fiação. Depois de mexer em `App/`, compile:

```bash
test -f Config/Google.xcconfig || cp Config/Google.example.xcconfig Config/Google.xcconfig
xcodegen generate
xcodebuild -project OkamiUNI.xcodeproj -scheme OkamiUNI -configuration Debug build 2>&1 | grep -E "error:|BUILD"
```

Nunca rode `Tools/rodar.sh` para verificar: ele **abre o app**. Verificação de interface é o harness offscreen (`Packages/UNIShell/Tests/UNIShellTests/RenderHarness.swift`, `Render.snapshot`).

---

## Estrutura de arquivos

### Renomeados (`git mv`, sem typealias)

| De | Para | Responsabilidade |
|---|---|---|
| `Packages/UNICore/Sources/UNICore/OnDeviceTextAssistant.swift` | `.../TextAssistant.swift` | Contrato puro do assistente de texto: contextos, turnos, ações de escrita, erro |
| `Packages/UNICore/Sources/UNICore/OnDeviceAssistantMailContext+Message.swift` | `.../AssistantMailContext+Message.swift` | Tradução do modelo do app para a fronteira factual |
| `Packages/UNICore/Sources/UNICore/OnDeviceMessageAnalysis.swift` | `.../MessageAnalysis.swift` | Contrato puro da análise persistida por mensagem |
| `Packages/UNICore/Tests/UNICoreTests/OnDeviceTextAssistantTests.swift` | `.../TextAssistantTests.swift` | Testes do contrato |
| `Packages/UNICore/Tests/UNICoreTests/OnDeviceAssistantMailContextTests.swift` | `.../AssistantMailContextTests.swift` | Testes da tradução |
| `Packages/UNICore/Tests/UNICoreTests/OnDeviceMessageAnalysisTests.swift` | `.../MessageAnalysisTests.swift` | Testes do contrato de análise |
| `Packages/UNIShell/Sources/UNIShell/Support/OnDeviceAssistantBridge.swift` | `.../Support/AssistantBridge.swift` | Liga superfícies do shell ao `TextAssisting` |
| `Packages/UNIShell/Tests/UNIShellTests/OnDeviceAssistantBridgeTests.swift` | `.../AssistantBridgeTests.swift` | Testes da ponte |
| `Packages/UNIShell/Sources/UNIShell/Inbox/LocalAssistantPanel.swift` | `.../Inbox/AssistantPanel.swift` | A view do painel (a máquina de estado sai daqui na Task 6) |
| `Packages/UNIShell/Tests/UNIShellTests/LocalAssistantPanelTests.swift` | `.../AssistantPanelTests.swift` | Testes do painel |
| `Packages/UNISync/Tests/UNISyncTests/FoundationModelsTextAssistantTests.swift` | `.../AssistantPromptTests.swift` | Testes do prompt compartilhado pelos quatro adaptadores |

### Criados

| Arquivo | Responsabilidade |
|---|---|
| `Packages/UNISync/Sources/UNISync/AssistantDestination.swift` | `AssistantDestination` — `label`/`detail`/`isLocal` derivados de `AssistantSettings` |
| `Packages/UNISync/Sources/UNISync/AssistantAvailability.swift` | `AssistantAvailability` + `AssistantAvailabilityModel` observável |
| `Packages/UNISync/Sources/UNISync/AssistantURLSessionFactory.swift` | Deriva uma `URLSession` com `timeoutIntervalForRequest` **e** `ForResource` |
| `Packages/UNISync/Sources/UNISync/CachedAssistantCLIDiscovery.swift` | Cache de 60 s da varredura de CLIs, com `invalidate()` |
| `Packages/UNISync/Sources/UNISync/RoutedMessageAnalyzer.swift` | Escolhe motor de análise por chamada, conforme `automaticAnalysis` |
| `Packages/UNISync/Sources/UNISync/TextAssistantMessageAnalyzer.swift` | Análise por JSON estrito pelo provedor configurado |
| `Packages/UNISync/Sources/UNISync/Database/AnalysisQueueState.swift` | Estado persistido `running`/`paused(reason)` da fila de análise |
| `Packages/UNIShell/Sources/UNIShell/Inbox/AssistantConversation.swift` | A única máquina de estado: transcript, `isLoading`, `failure`, `task`, `briefing` |
| `Packages/UNIShell/Sources/UNIShell/Support/AssistantMarkdown.swift` | `AssistantMarkdown` + `AssistantMarkdownBlock`, saídos do popover |
| `Packages/UNIShell/Sources/UNIShell/Support/AssistantFailure.swift` | `AssistantFailure`, `AssistantFailure.Recovery` e `AssistantFailureBand` |
| `Packages/UNISync/Tests/UNISyncTests/AssistantDestinationTests.swift` | Um caso por provedor da tabela 1.2 |
| `Packages/UNISync/Tests/UNISyncTests/AssistantAvailabilityTests.swift` | Cada provedor em cada estado de credencial |
| `Packages/UNISync/Tests/UNISyncTests/CachedAssistantCLIDiscoveryTests.swift` | Validade de 60 s e `invalidate()` |
| `Packages/UNISync/Tests/UNISyncTests/RoutedMessageAnalyzerTests.swift` | Rota por configuração e JSON estrito |
| `Packages/UNISync/Tests/UNISyncTests/Golden/workspace-prompt.txt` | Golden do prompt de workspace |
| `Packages/UNIShell/Tests/UNIShellTests/AssistantConversationTests.swift` | `draftReply`, `cancel`, histórico 16, `emptyResponse`, `briefing` |
| `Packages/UNIShell/Tests/UNIShellTests/AssistantFailureTests.swift` | Cada enum de adaptador → mensagem e recuperação |
| `Packages/UNIShell/Tests/UNIShellTests/AssistantMarkdownTests.swift` | Blocos e turno `.draft` sem Markdown |

### Modificados (arquivo → o que muda)

| Arquivo | Mudança |
|---|---|
| `Packages/UNISync/Sources/UNISync/FoundationModelsTextAssistant.swift` | `FoundationModelsTextAssistantPrompt` → `AssistantPrompt`; `Budget` ganha `maximumTextCharacters`, `maximumWorkspaceEmails`, `maximumWorkspaceAgendaItems`; `transform` e `render(_:budget:)` passam a respeitá-los; idioma sai do prompt fixo |
| `Packages/UNISync/Sources/UNISync/AssistantSettings.swift` | `generatedInstructions()` sempre emite idioma; `automaticAnalysis`; `currentSchemaVersion = 5` |
| `Packages/UNISync/Sources/UNISync/AssistantSettingsStore.swift` | `addDidChangeHandler(_:)` publicando cada `save`/`reset` |
| `Packages/UNISync/Sources/UNISync/AssistantRouter.swift` | Timeouts 120; sessão com `timeoutIntervalForResource`; cache de CLIs; `assistantAvailability()`; `destination()` |
| `Packages/UNISync/Sources/UNISync/AssistantCLITextAssistant.swift` | `processFailed(exitCode:stderrTail:)`; stderr capturado (4 KiB, cauda); faixa de timeout 30–300 |
| `Packages/UNISync/Sources/UNISync/LiteLLMOAuthCoordinator.swift` | Vira `actor` + `LiteLLMOAuthSessionState` observável |
| `Packages/UNISync/Sources/UNISync/AssistantProviderOAuthCoordinator.swift` | Vira `actor` + `AssistantProviderOAuthSessionState` observável |
| `Packages/UNISync/Sources/UNISync/MessageIntelligenceCoordinator.swift` | Pausa a fila após 3 falhas de auth/rede, com estado persistido |
| `Packages/UNISync/Sources/UNISync/Database/SyncDatabase.swift` | Migração `v15`: tabela do estado da fila de análise |
| `Packages/UNISync/Sources/UNISync/AppComposition.swift` | `RoutedMessageAnalyzer`, `assistantAvailability`, discovery em cache |
| `Packages/UNIShell/Sources/UNIShell/Inbox/FolderSidebar.swift` | `IntelligencePresentation` com `needsSetup`/`needsSignIn`, sem `.configuredAssistant` |
| `Packages/UNIShell/Sources/UNIShell/Inbox/DashboardScreen.swift` | Consome `AssistantConversation`; `run/runDraft/runSuggestion` removidos |
| `Packages/UNIShell/Sources/UNIShell/Inbox/InboxScreen.swift` | Dono da `AssistantConversation`; passa `AssistantDestination` |
| `Packages/UNIShell/Sources/UNIShell/Inbox/ReaderIntelligencePopover.swift` | Usa `AssistantMarkdown` e `AssistantConversation` |
| `Packages/UNIShell/Sources/UNIShell/Windows/MessageWindow.swift` | Recebe `AssistantConversation` por injeção |
| `Packages/UNIShell/Sources/UNIShell/Windows/SettingsSections.swift` | Estado dos coordenadores; toggle de análise automática; cópia condicional |
| `App/OkamiUNIApp.swift` | `IntelligencePresentation` vinda de `assistantAvailability`, sem `.configuredAssistant` fixo |
| `README.md` | "sem mandar conteúdo para servidor algum" vira condicional ao provedor |
| `docs/decisoes-de-engenharia.md` | Cinco entradas novas (§1.10) |

---

### Task 1: Renomes do contrato de texto (tabela 1.1, grupo A)

O protocolo vive em UNICore e é implementado em UNISync e consumido em UNIShell e `App/`. Renomear em um pacote só não compila: esta tarefa é atômica nos quatro.

**Files**
- Rename `Packages/UNICore/Sources/UNICore/OnDeviceTextAssistant.swift` → `Packages/UNICore/Sources/UNICore/TextAssistant.swift` (via `git mv`)
- Rename `Packages/UNICore/Sources/UNICore/OnDeviceAssistantMailContext+Message.swift` → `Packages/UNICore/Sources/UNICore/AssistantMailContext+Message.swift` (via `git mv`)
- Rename `Packages/UNICore/Tests/UNICoreTests/OnDeviceTextAssistantTests.swift` → `.../TextAssistantTests.swift` (via `git mv`)
- Rename `Packages/UNICore/Tests/UNICoreTests/OnDeviceAssistantMailContextTests.swift` → `.../AssistantMailContextTests.swift` (via `git mv`)
- Modify: todo `.swift` versionado que cite os nomes antigos (25 arquivos hoje; `git grep -l` na etapa 1 dá a lista exata)

**Interfaces**
- Consumes: nada novo.
- Produces (UNICore, público):
  ```swift
  public protocol TextAssisting: Sendable {
      var modelVersion: String { get }
      func availability() async -> OnDeviceMessageAnalysisAvailability   // renomeado na Task 2
      func answer(question: String, in conversation: AssistantConversationSnapshot) async throws -> String
      func transform(_ text: String, using action: WritingAction, context: AssistantMailContext?) async throws -> String
  }
  public enum AssistantMailContext: Sendable, Hashable {
      case email(AssistantEmailContext)
      case conversation([AssistantEmailContext])
      case workspace(AssistantWorkspaceContext)
  }
  public struct AssistantConversationSnapshot: Sendable, Hashable {
      public let mailContext: AssistantMailContext
      public let turns: [AssistantTurn]
  }
  public struct AssistantTurn: Sendable, Hashable { public let role: AssistantTurnRole; public let text: String }
  public enum AssistantTurnRole: String, Sendable, Hashable { case user, assistant }
  public enum WritingAction: Sendable, Hashable { /* casos inalterados */ }
  public enum TextAssistantError: Error, Sendable, Equatable, LocalizedError { /* casos inalterados */ }
  ```
  Junto vão os contextos que carregam o mesmo prefixo mentiroso (extensão coerente da tabela 1.1, que só nomeia o guarda-chuva): `AssistantEmailContext`, `AssistantMailboxContext`, `AssistantAgendaContext`, `AssistantWorkspaceEmailContext`, `AssistantPendingContext`, `AssistantWorkspaceContext`.

**Steps**

- [ ] Registrar o alvo antes de mexer: rode
      ```bash
      git grep -c -E 'OnDeviceTextAssisting|OnDeviceAssistantMailContext|OnDeviceAssistantConversation|OnDeviceAssistantTurn|OnDeviceWritingAction|OnDeviceTextAssistantError|OnDeviceAssistant(Email|Mailbox|Agenda|WorkspaceEmail|Workspace|Pending)Context' -- '*.swift' | sort -t: -k2 -rn
      ```
      e guarde a saída no corpo do commit. Ela é a prova de que nada ficou para trás.

- [ ] Escrever o teste que falha. Em `Packages/UNICore/Tests/UNICoreTests/AssistantNamingTests.swift` (arquivo novo):
      ```swift
      import Foundation
      import Testing
      @testable import UNICore

      @Suite("Nomes do assistente")
      struct AssistantNamingTests {
          /// A tabela 1.1 da spec proíbe typealias de transição: o nome novo tem
          /// de ser o único nome. Este teste não compila enquanto o rename não
          /// acontecer, e é essa a falha esperada.
          @Test("o contrato de texto não carrega mais o prefixo OnDevice")
          func contractIsRenamed() {
              let turn = AssistantTurn(role: .user, text: "oi")
              let snapshot = AssistantConversationSnapshot(
                  mailContext: .email(
                      AssistantEmailContext(subject: "Assunto", sender: "a@b.c", body: "corpo")
                  ),
                  turns: [turn]
              )
              #expect(snapshot.turns.count == 1)
              #expect(snapshot.turns[0].role == AssistantTurnRole.user)
              #expect(WritingAction.draftReply == WritingAction.draftReply)
              #expect(TextAssistantError.emptyResponse.errorDescription?.isEmpty == false)
              #expect(String(describing: (any TextAssisting).self).contains("TextAssisting"))
          }
      }
      ```

- [ ] Rodar e ver falhar:
      ```bash
      swift test --package-path Packages/UNICore --filter AssistantNamingTests
      ```
      Esperado: erro de compilação `cannot find 'AssistantTurn' in scope` (e o mesmo para `AssistantConversationSnapshot`, `AssistantEmailContext`, `WritingAction`, `TextAssistantError`, `TextAssisting`). Falha de compilação **é** a falha esperada aqui: o rename é o defeito.

- [ ] Renomear os arquivos:
      ```bash
      git mv Packages/UNICore/Sources/UNICore/OnDeviceTextAssistant.swift \
             Packages/UNICore/Sources/UNICore/TextAssistant.swift
      git mv Packages/UNICore/Sources/UNICore/OnDeviceAssistantMailContext+Message.swift \
             Packages/UNICore/Sources/UNICore/AssistantMailContext+Message.swift
      git mv Packages/UNICore/Tests/UNICoreTests/OnDeviceTextAssistantTests.swift \
             Packages/UNICore/Tests/UNICoreTests/TextAssistantTests.swift
      git mv Packages/UNICore/Tests/UNICoreTests/OnDeviceAssistantMailContextTests.swift \
             Packages/UNICore/Tests/UNICoreTests/AssistantMailContextTests.swift
      ```

- [ ] Aplicar os nomes, do mais longo para o mais curto (a ordem evita que um prefixo coma o outro):
      ```bash
      files=$(git ls-files '*.swift')
      perl -pi -e '
        s/\bOnDeviceAssistantWorkspaceEmailContext\b/AssistantWorkspaceEmailContext/g;
        s/\bOnDeviceAssistantWorkspaceContext\b/AssistantWorkspaceContext/g;
        s/\bOnDeviceAssistantMailboxContext\b/AssistantMailboxContext/g;
        s/\bOnDeviceAssistantPendingContext\b/AssistantPendingContext/g;
        s/\bOnDeviceAssistantAgendaContext\b/AssistantAgendaContext/g;
        s/\bOnDeviceAssistantEmailContext\b/AssistantEmailContext/g;
        s/\bOnDeviceAssistantMailContextTests\b/AssistantMailContextTests/g;
        s/\bOnDeviceAssistantMailContext\b/AssistantMailContext/g;
        s/\bOnDeviceAssistantConversation\b/AssistantConversationSnapshot/g;
        s/\bOnDeviceAssistantTurnRole\b/AssistantTurnRole/g;
        s/\bOnDeviceAssistantTurn\b/AssistantTurn/g;
        s/\bOnDeviceWritingAction\b/WritingAction/g;
        s/\bOnDeviceTextAssistantTests\b/TextAssistantTests/g;
        s/\bOnDeviceTextAssistantError\b/TextAssistantError/g;
        s/\bOnDeviceTextAssisting\b/TextAssisting/g;
      ' $files
      git grep -n -E 'OnDeviceTextAssisting|OnDeviceAssistantMailContext|OnDeviceAssistantConversation|OnDeviceAssistantTurn|OnDeviceWritingAction|OnDeviceTextAssistantError' -- '*.swift' || echo "nenhum nome antigo restou"
      ```

- [ ] Ajustar à mão o que o `perl` não alcança: comentários que dizem "assistente local" onde o tipo agora é neutro. Em `Packages/UNICore/Sources/UNICore/TextAssistant.swift`, o doc-comment de `AssistantEmailContext` (linha 3 do arquivo) passa de "contexto factual para o assistente local" para "contexto factual para o assistente"; o de `TextAssisting` ("A porta assíncrona…") perde a palavra "local"; `TextAssistantError.errorDescription` troca "O assistente local" por "O assistente" nos quatro casos que citam:
      ```swift
      case .unavailable(.available):
          return "O assistente não está disponível neste momento."
      case .unavailable(.deviceNotEligible):
          return "Este dispositivo não é elegível para a Apple Intelligence."
      case .unavailable(.appleIntelligenceNotEnabled):
          return "A Apple Intelligence está desativada neste dispositivo."
      case .unavailable(.modelNotReady):
          return "O modelo da Apple Intelligence ainda não está pronto."
      case .emptyResponse:
          return "O assistente devolveu uma resposta vazia."
      ```

- [ ] Rodar e ver passar, pacote a pacote:
      ```bash
      swift test --package-path Packages/UNICore
      swift test --package-path Packages/UNISync
      swift test --package-path Packages/UNIShell
      ```
      Esperado: três `✔ Test run with N tests ... passed`, nenhum aviso de `OnDevice…` não encontrado.

- [ ] Compilar o app (é ele que consome `composition.textAssistant`):
      ```bash
      xcodegen generate && xcodebuild -project OkamiUNI.xcodeproj -scheme OkamiUNI -configuration Debug build 2>&1 | grep -E "error:|BUILD"
      ```
      Esperado: `** BUILD SUCCEEDED **`.

- [ ] Commit:
      ```bash
      git add -A && git commit -m "refactor: TextAssisting e AssistantMailContext sem o prefixo OnDevice

O contrato atende Grok, LiteLLM, Codex e CLI; o nome dizia 'no
dispositivo' em todos eles. Tabela 1.1 da spec, grupo do texto.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
      ```

---

### Task 2: Renomes da análise, da ponte, do painel e do prompt (tabela 1.1, grupo B)

**Files**
- Rename `Packages/UNICore/Sources/UNICore/OnDeviceMessageAnalysis.swift` → `.../MessageAnalysis.swift`
- Rename `Packages/UNICore/Tests/UNICoreTests/OnDeviceMessageAnalysisTests.swift` → `.../MessageAnalysisTests.swift`
- Rename `Packages/UNIShell/Sources/UNIShell/Support/OnDeviceAssistantBridge.swift` → `.../Support/AssistantBridge.swift`
- Rename `Packages/UNIShell/Tests/UNIShellTests/OnDeviceAssistantBridgeTests.swift` → `.../AssistantBridgeTests.swift`
- Rename `Packages/UNIShell/Sources/UNIShell/Inbox/LocalAssistantPanel.swift` → `.../Inbox/AssistantPanel.swift`
- Rename `Packages/UNIShell/Tests/UNIShellTests/LocalAssistantPanelTests.swift` → `.../AssistantPanelTests.swift`
- Rename `Packages/UNISync/Tests/UNISyncTests/FoundationModelsTextAssistantTests.swift` → `.../AssistantPromptTests.swift`
- Modify: todo `.swift` versionado que cite os nomes antigos

**Interfaces**
- Produces (UNICore, público):
  ```swift
  public enum AppleIntelligenceAvailability: Sendable, Hashable {
      case available, deviceNotEligible, appleIntelligenceNotEnabled, modelNotReady
      public var isAvailable: Bool { self == .available }
  }
  public protocol MessageAnalyzing: Sendable {
      var modelVersion: String { get }
      func availability() async -> AppleIntelligenceAvailability
      func analyze(_ input: MessageAnalysisInput) async throws -> MessageAnalysisResult
  }
  public struct MessageAnalysisInput: Sendable, Hashable { /* campos inalterados */ }
  public struct MessageAnalysisResult: Sendable, Hashable { /* campos inalterados */ }
  public enum MessageAnalysisError: Error, Sendable, Equatable, LocalizedError { /* casos inalterados */ }
  ```
- Produces (UNISync, interno): `enum AssistantPrompt` (era `FoundationModelsTextAssistantPrompt`). `FoundationModelsTextAssistantValidation` **mantém o nome** — a spec §4.2 ainda o cita.
- Produces (UNIShell, público): `AssistantPanel`, `AssistantPanelDebugState`, `AssistantConversation`, `AssistantScope`, `AssistantSuggestion`, `AssistantContext`, `AssistantMessage`, `AssistantSpeaker`, `AssistantRequest`, `AssistantBridge`.

**Steps**

- [ ] Escrever o teste que falha. Em `Packages/UNIShell/Tests/UNIShellTests/AssistantNamingTests.swift` (arquivo novo):
      ```swift
      import Foundation
      import Testing
      import UNICore
      @testable import UNIShell

      @Suite("Nomes do assistente no shell")
      @MainActor
      struct AssistantShellNamingTests {
          @Test("painel, escopo e sugestões perderam o prefixo Local")
          func shellTypesAreRenamed() {
              let scope = AssistantScope.workspace
              #expect(scope.suggestions.count == AssistantSuggestion.workspaceDefaults.count)
              let context = AssistantContext(subject: "Assunto", sender: "a@b.c")
              #expect(context.title == "Assunto")
              let message = AssistantMessage(speaker: .assistant, text: "ok")
              #expect(message.speaker == AssistantSpeaker.assistant)
              let request = AssistantRequest(context: context, question: "q", conversation: [message])
              #expect(request.conversation.count == 1)
              #expect(AssistantPanel.defaultWidth == 360)
              #expect(AppleIntelligenceAvailability.available.isAvailable)
          }
      }
      ```

- [ ] Rodar e ver falhar:
      ```bash
      swift test --package-path Packages/UNIShell --filter AssistantShellNamingTests
      ```
      Esperado: `cannot find 'AssistantScope' in scope`, `cannot find 'AssistantSuggestion' in scope`, `cannot find type 'AppleIntelligenceAvailability' in scope`.

- [ ] Renomear os arquivos:
      ```bash
      git mv Packages/UNICore/Sources/UNICore/OnDeviceMessageAnalysis.swift \
             Packages/UNICore/Sources/UNICore/MessageAnalysis.swift
      git mv Packages/UNICore/Tests/UNICoreTests/OnDeviceMessageAnalysisTests.swift \
             Packages/UNICore/Tests/UNICoreTests/MessageAnalysisTests.swift
      git mv Packages/UNIShell/Sources/UNIShell/Support/OnDeviceAssistantBridge.swift \
             Packages/UNIShell/Sources/UNIShell/Support/AssistantBridge.swift
      git mv Packages/UNIShell/Tests/UNIShellTests/OnDeviceAssistantBridgeTests.swift \
             Packages/UNIShell/Tests/UNIShellTests/AssistantBridgeTests.swift
      git mv Packages/UNIShell/Sources/UNIShell/Inbox/LocalAssistantPanel.swift \
             Packages/UNIShell/Sources/UNIShell/Inbox/AssistantPanel.swift
      git mv Packages/UNIShell/Tests/UNIShellTests/LocalAssistantPanelTests.swift \
             Packages/UNIShell/Tests/UNIShellTests/AssistantPanelTests.swift
      git mv Packages/UNISync/Tests/UNISyncTests/FoundationModelsTextAssistantTests.swift \
             Packages/UNISync/Tests/UNISyncTests/AssistantPromptTests.swift
      ```

- [ ] Aplicar os nomes, do mais longo para o mais curto:
      ```bash
      files=$(git ls-files '*.swift')
      perl -pi -e '
        s/\bOnDeviceMessageAnalysisAvailability\b/AppleIntelligenceAvailability/g;
        s/\bOnDeviceMessageAnalysisInput\b/MessageAnalysisInput/g;
        s/\bOnDeviceMessageAnalysisResult\b/MessageAnalysisResult/g;
        s/\bOnDeviceMessageAnalysisError\b/MessageAnalysisError/g;
        s/\bOnDeviceMessageAnalysisTests\b/MessageAnalysisTests/g;
        s/\bOnDeviceMessageAnalyzing\b/MessageAnalyzing/g;
        s/\bOnDeviceAssistantBridgeTests\b/AssistantBridgeTests/g;
        s/\bOnDeviceAssistantBridge\b/AssistantBridge/g;
        s/\bFoundationModelsTextAssistantPrompt\b/AssistantPrompt/g;
        s/\bFoundationModelsTextAssistantTests\b/AssistantPromptTests/g;
        s/\bLocalAssistantPanelDebugState\b/AssistantPanelDebugState/g;
        s/\bLocalAssistantPanelTests\b/AssistantPanelTests/g;
        s/\bLocalAssistantPanel\b/AssistantPanel/g;
        s/\bLocalAssistantConversation\b/AssistantConversation/g;
        s/\bLocalAssistantSuggestion\b/AssistantSuggestion/g;
        s/\bLocalAssistantMode\b/AssistantScope/g;
        s/\bLocalAssistantContext\b/AssistantContext/g;
        s/\bLocalAssistantMessage\b/AssistantMessage/g;
        s/\bLocalAssistantSpeaker\b/AssistantSpeaker/g;
        s/\bLocalAssistantRequest\b/AssistantRequest/g;
        s/\bLocalAssistantCopy\b/AssistantCopy/g;
      ' $files
      git grep -n -E 'OnDeviceMessageAnalys|OnDeviceAssistantBridge|FoundationModelsTextAssistantPrompt|LocalAssistant' -- '*.swift' || echo "nenhum nome antigo restou"
      ```

- [ ] Corrigir os nomes de `@Suite` que o `perl` não toca porque são literais soltos. Em `Packages/UNISync/Tests/UNISyncTests/AssistantPromptTests.swift`, trocar `@Suite("Assistente de texto local")` (ou o rótulo que estiver lá) por `@Suite("Prompt do assistente")`. Em `Packages/UNIShell/Tests/UNIShellTests/AssistantPanelTests.swift`, o rótulo vira `@Suite("Painel do assistente")`.

- [ ] Rodar e ver passar:
      ```bash
      swift test --package-path Packages/UNICore
      swift test --package-path Packages/UNISync
      swift test --package-path Packages/UNIShell
      xcodegen generate && xcodebuild -project OkamiUNI.xcodeproj -scheme OkamiUNI -configuration Debug build 2>&1 | grep -E "error:|BUILD"
      ```
      Esperado: três suítes verdes e `** BUILD SUCCEEDED **`.

- [ ] Commit:
      ```bash
      git add -A && git commit -m "refactor: análise, ponte, painel e prompt sem prefixo mentiroso

AppleIntelligenceAvailability passa a nomear só o que é do Foundation
Models; AssistantPrompt é dos quatro adaptadores. Tabela 1.1, grupo B.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
      ```

---

### Task 3: `AssistantDestination` (spec 1.2)

Um único valor responde "para onde vai o meu email quando eu aperto isto?".

**Files**
- Create `Packages/UNISync/Sources/UNISync/AssistantDestination.swift`
- Create `Packages/UNISync/Tests/UNISyncTests/AssistantDestinationTests.swift`

**Interfaces**
- Consumes: `AssistantSettings` (`Packages/UNISync/Sources/UNISync/AssistantSettings.swift:429`), `AssistantProvider` (`:7`), `AssistantProviderOAuthKind` (`:193`), `AssistantCLIKind.displayName` (`AssistantCLIDiscovery.swift:16`), `OpenAICompatibleAssistantConfiguration.authenticationMode` (`:68`).
- Produces:
  ```swift
  public struct AssistantDestination: Sendable, Hashable {
      public let label: String
      public let detail: String
      /// `true` só no Foundation Models. É o que autoriza a frase "Nada sai deste Mac."
      public let isLocal: Bool
      public init(label: String, detail: String, isLocal: Bool)
      public init(settings: AssistantSettings)
  }
  ```

**Steps**

- [ ] Escrever o teste que falha. `Packages/UNISync/Tests/UNISyncTests/AssistantDestinationTests.swift`:
      ```swift
      import Foundation
      import Testing
      @testable import UNISync

      @Suite("Destino do assistente")
      struct AssistantDestinationTests {
          @Test("o Foundation Models é o único que pode prometer que nada sai")
          func localDestination() {
              let destination = AssistantDestination(settings: .init(provider: .foundationModels))
              #expect(destination.label == "Neste Mac")
              #expect(destination.detail == "Nada sai deste Mac.")
              #expect(destination.isLocal)
          }

          @Test("assinatura direta nomeia o provedor e para onde o texto vai")
          func providerOAuthDestinations() {
              let grok = AssistantDestination(settings: .init(
                  provider: .providerOAuth,
                  providerOAuth: .init(kind: .xAI, model: "grok-4.6")
              ))
              #expect(grok.label == "Grok · xAI")
              #expect(grok.detail == "Sai deste Mac para a xAI.")
              #expect(!grok.isLocal)

              let codex = AssistantDestination(settings: .init(
                  provider: .providerOAuth,
                  providerOAuth: .init(kind: .codex, model: "gpt-5-codex")
              ))
              #expect(codex.label == "Codex · ChatGPT")
              #expect(codex.detail == "Sai deste Mac pelo Codex instalado.")
          }

          @Test("o endpoint compatível mostra o host, e PKCE se identifica como LiteLLM")
          func openAICompatibleDestinations() {
              let api = AssistantDestination(settings: .init(
                  provider: .openAICompatible,
                  openAICompatible: .init(
                      endpoint: "https://api.example.com/v1",
                      model: "gpt-4o-mini",
                      credentialID: "primary",
                      authenticationMode: .apiKey
                  )
              ))
              #expect(api.label == "API · api.example.com")
              #expect(api.detail == "Sai deste Mac para api.example.com.")

              let proxy = AssistantDestination(settings: .init(
                  provider: .openAICompatible,
                  openAICompatible: .init(
                      endpoint: "http://127.0.0.1:4000/v1",
                      model: "gateway",
                      credentialID: "team",
                      authenticationMode: .litellmOAuthPKCE
                  )
              ))
              #expect(proxy.label == "LiteLLM · 127.0.0.1")
              #expect(proxy.detail == "Sai deste Mac para 127.0.0.1.")
          }

          @Test("endpoint em branco não inventa host")
          func openAICompatibleWithoutEndpoint() {
              let destination = AssistantDestination(settings: .init(
                  provider: .openAICompatible,
                  openAICompatible: .init(endpoint: "", model: "m", credentialID: "c")
              ))
              #expect(destination.label == "API · sem endpoint")
              #expect(destination.detail == "Informe o endpoint nos Ajustes.")
              #expect(!destination.isLocal)
          }

          @Test("cada CLI aparece pelo nome do binário que a pessoa instalou")
          func cliDestinations() {
              let expected: [(AssistantCLIKind, String)] = [
                  (.claude, "Claude Code · CLI"),
                  (.codex, "Codex CLI · CLI"),
                  (.openCode, "OpenCode · CLI"),
              ]
              for (kind, label) in expected {
                  let destination = AssistantDestination(settings: .init(provider: .cli, cli: .init(kind: kind)))
                  #expect(destination.label == label)
                  #expect(destination.detail == "Sai deste Mac pelo CLI instalado.")
                  #expect(!destination.isLocal)
              }
          }
      }
      ```

- [ ] Rodar e ver falhar:
      ```bash
      swift test --package-path Packages/UNISync --filter AssistantDestinationTests
      ```
      Esperado: `cannot find 'AssistantDestination' in scope`.

- [ ] Implementar. `Packages/UNISync/Sources/UNISync/AssistantDestination.swift`:
      ```swift
      import Foundation

      /// Para onde vai o conteúdo quando a pessoa aciona o assistente.
      ///
      /// Existe porque a cópia do app dizia "local" com Grok, LiteLLM, Codex e
      /// CLI selecionados. Toda superfície que fala do assistente lê daqui — não
      /// há segunda fonte, e não há frase sobre privacidade que não passe por
      /// `isLocal`.
      public struct AssistantDestination: Sendable, Hashable {
          public let label: String
          public let detail: String
          /// `true` só no Foundation Models. É o que autoriza "Nada sai deste Mac."
          public let isLocal: Bool

          public init(label: String, detail: String, isLocal: Bool) {
              self.label = label
              self.detail = detail
              self.isLocal = isLocal
          }

          public init(settings: AssistantSettings) {
              switch settings.provider {
              case .foundationModels:
                  self.init(label: "Neste Mac", detail: "Nada sai deste Mac.", isLocal: true)
              case .providerOAuth:
                  switch settings.providerOAuth.kind {
                  case .xAI:
                      self.init(
                          label: "Grok · xAI",
                          detail: "Sai deste Mac para a xAI.",
                          isLocal: false
                      )
                  case .codex:
                      self.init(
                          label: "Codex · ChatGPT",
                          detail: "Sai deste Mac pelo Codex instalado.",
                          isLocal: false
                      )
                  }
              case .openAICompatible:
                  let family = settings.openAICompatible.authenticationMode == .litellmOAuthPKCE
                      ? "LiteLLM"
                      : "API"
                  guard let host = Self.host(of: settings.openAICompatible.endpoint) else {
                      self.init(
                          label: "\(family) · sem endpoint",
                          detail: "Informe o endpoint nos Ajustes.",
                          isLocal: false
                      )
                      return
                  }
                  self.init(
                      label: "\(family) · \(host)",
                      detail: "Sai deste Mac para \(host).",
                      isLocal: false
                  )
              case .cli:
                  self.init(
                      label: "\(settings.cli.kind.displayName) · CLI",
                      detail: "Sai deste Mac pelo CLI instalado.",
                      isLocal: false
                  )
              }
          }

          /// Só o host: porta, caminho e query não dizem nada à pessoa e podem
          /// carregar identificador de time num proxy compartilhado.
          static func host(of endpoint: String) -> String? {
              let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
              guard !trimmed.isEmpty,
                    let host = URLComponents(string: trimmed)?.host?.lowercased(),
                    !host.isEmpty
              else { return nil }
              return host
          }
      }
      ```

- [ ] Rodar e ver passar:
      ```bash
      swift test --package-path Packages/UNISync --filter AssistantDestinationTests
      ```
      Esperado: `✔ Test run with 5 tests in 1 suite passed`.

- [ ] Provar por mutação: troque `isLocal: true` por `isLocal: false` no ramo `.foundationModels` e confirme que `localDestination` falha; desfaça. Troque `"LiteLLM"` por `"API"` e confirme que `openAICompatibleDestinations` falha; desfaça.

- [ ] Suíte do pacote e commit:
      ```bash
      swift test --package-path Packages/UNISync
      git add -A && git commit -m "feat: AssistantDestination diz para onde o email vai

Um valor só, derivado das preferências, com label, detail e isLocal.
Spec 1.2.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
      ```

---

### Task 4: Orçamento e tempo atravessando prompt, router e adaptadores (spec 1.4)

Hoje `AssistantPrompt.transform` corta o texto em 8 000 caracteres fixos (`FoundationModelsTextAssistant.swift:352`) e `render(_ workspace:)` (`:429`) ignora o orçamento e crava 24 emails / 32 compromissos. O commit `0a6330a` só passou o `Budget` para o contexto de email.

**Files**
- Modify `Packages/UNISync/Sources/UNISync/FoundationModelsTextAssistant.swift` (`Budget` em `:192-208`; `transform` em `:308-356`; `mailContext` em `:394-413`; `render(_ workspace:)` em `:429-506`; `actionDescription` em `:358-377`)
- Modify `Packages/UNISync/Sources/UNISync/AssistantRouter.swift` (`init` em `:34-57`, `providerOAuthAssistant` em `:250`)
- Modify `Packages/UNISync/Sources/UNISync/AssistantCLITextAssistant.swift` (`requestTimeout` em `:451-462`)
- Create `Packages/UNISync/Sources/UNISync/AssistantURLSessionFactory.swift`
- Modify `Packages/UNISync/Tests/UNISyncTests/AssistantPromptTests.swift`
- Modify `Packages/UNISync/Tests/UNISyncTests/AssistantRouterTests.swift`

**Interfaces**
- Produces:
  ```swift
  extension AssistantPrompt {
      static let maximumCustomInstructionCharacters = 6_000

      struct Budget: Sendable, Equatable {
          var maximumBodyCharacters: Int
          var maximumTextCharacters: Int
          var maximumEmails: Int
          var maximumHistoryTurns: Int
          var maximumWorkspaceEmails: Int
          var maximumWorkspaceAgendaItems: Int

          static let onDevice: Budget
          static let configured: Budget
      }

      static func transform(text: String, action: WritingAction, context: AssistantMailContext?, budget: Budget) -> String
      static func render(_ workspace: AssistantWorkspaceContext, budget: Budget) -> String
  }

  enum AssistantURLSessionFactory {
      /// Copia a configuração da sessão recebida (inclusive `protocolClasses`,
      /// que é o que faz o StubURLProtocol dos testes continuar valendo) e crava
      /// os dois tempos.
      static func timed(basedOn session: URLSession, timeout: TimeInterval) -> URLSession
  }
  ```
- Consumes: `OpenAICompatibleTextAssistant.init(configuration:authorizationToken:additionalInstructions:session:requestTimeout:)` (`OpenAICompatibleTextAssistant.swift:72`), `AssistantProviderOAuthTextAssistant.init(configuration:accessToken:additionalInstructions:session:requestTimeout:)` (`AssistantProviderOAuthTextAssistant.swift:37`).

**Steps**

- [ ] Escrever os testes que falham. Acrescentar a `Packages/UNISync/Tests/UNISyncTests/AssistantPromptTests.swift`:
      ```swift
      @Test("com a IA configurada, o texto de escrita não é elidido em 8 mil")
      func configuredTransformKeepsLongText() {
          let text = String(repeating: "a", count: 100_000)
          let prompt = AssistantPrompt.transform(
              text: text,
              action: .rewriteForClarity,
              context: nil,
              budget: .configured
          )
          #expect(!prompt.contains(AssistantPrompt.omittedMiddleMarker))
          #expect(prompt.contains(String(repeating: "a", count: 100_000)))

          let local = AssistantPrompt.transform(
              text: text,
              action: .rewriteForClarity,
              context: nil,
              budget: .onDevice
          )
          #expect(local.contains(AssistantPrompt.omittedMiddleMarker))
      }

      @Test("o retrato do ambiente segue o orçamento: 100 emails cabem na IA configurada")
      func workspaceRespectsBudget() {
          let emails = (1...100).map { index in
              AssistantWorkspaceEmailContext(
                  id: "m\(index)", account: "eu@example.com", mailbox: "Hoje",
                  isRead: false, isFlagged: false,
                  subject: "Assunto \(index)", sender: "a\(index)@example.com",
                  recipients: ["eu@example.com"],
                  sentAt: Date(timeIntervalSince1970: 1_788_000_000),
                  snippet: "prévia \(index)"
              )
          }
          let workspace = AssistantWorkspaceContext(
              accounts: ["eu@example.com"], emailCount: 100, unreadCount: 100,
              mailboxes: [], emails: emails, agenda: []
          )
          let configured = AssistantPrompt.render(workspace, budget: .configured)
          #expect(configured.contains("Assunto 100"))
          #expect(!configured.contains("fora do recorte detalhado"))

          let local = AssistantPrompt.render(workspace, budget: .onDevice)
          #expect(local.contains("Assunto 24"))
          #expect(!local.contains("Assunto 25"))
          #expect(local.contains("[76 e-mail(s) fora do recorte detalhado"))
      }

      @Test("instrução personalizada cabe em 6 mil, não em 1,2 mil")
      func customInstructionBudget() {
          let instruction = String(repeating: "i", count: 5_000)
          let prompt = AssistantPrompt.transform(
              text: "texto",
              action: .customInstruction(instruction),
              context: nil,
              budget: .configured
          )
          #expect(prompt.contains(instruction))
          #expect(AssistantPrompt.maximumCustomInstructionCharacters == 6_000)
      }
      ```
      E, em `Packages/UNISync/Tests/UNISyncTests/AssistantRouterTests.swift`:
      ```swift
      @Test("o tempo padrão é 120 s e vale para pedido e para recurso")
      @available(macOS 26.0, *)
      func routerUsesGenerousTimeouts() throws {
          let base = URLSession(configuration: {
              let configuration = URLSessionConfiguration.ephemeral
              configuration.timeoutIntervalForRequest = 7
              configuration.timeoutIntervalForResource = 7
              configuration.protocolClasses = [StubURLProtocol.self]
              return configuration
          }())
          let timed = AssistantURLSessionFactory.timed(basedOn: base, timeout: 120)
          #expect(timed.configuration.timeoutIntervalForRequest == 120)
          #expect(timed.configuration.timeoutIntervalForResource == 120)
          #expect(timed.configuration.protocolClasses?.contains { $0 == StubURLProtocol.self } == true)
      }
      ```

- [ ] Rodar e ver falhar:
      ```bash
      swift test --package-path Packages/UNISync --filter 'AssistantPromptTests|AssistantRouterTests'
      ```
      Esperado: `extra argument 'budget' in call` em `AssistantPrompt.render`, `cannot find 'AssistantURLSessionFactory' in scope`, e `AssistantPrompt.maximumCustomInstructionCharacters` inexistente.

- [ ] Ampliar o `Budget`. Em `FoundationModelsTextAssistant.swift`, substituir o bloco `struct Budget` (linhas 190–208) por:
      ```swift
      /// Orçamento do prompt. A Foundation Models local tem janela curta; Grok,
      /// LiteLLM e CLI aguentam o email completo — e é isso que a pessoa pediu.
      /// Cada dimensão do prompt tem de estar aqui: um número cravado no corpo
      /// de `render` é exatamente o defeito que o commit 0a6330a deixou passar.
      struct Budget: Sendable, Equatable {
          var maximumBodyCharacters: Int
          var maximumTextCharacters: Int
          var maximumEmails: Int
          var maximumHistoryTurns: Int
          var maximumWorkspaceEmails: Int
          var maximumWorkspaceAgendaItems: Int

          static let onDevice = Budget(
              maximumBodyCharacters: AssistantPrompt.maximumTextCharacters,
              maximumTextCharacters: AssistantPrompt.maximumTextCharacters,
              maximumEmails: AssistantPrompt.maximumEmails,
              maximumHistoryTurns: AssistantPrompt.maximumHistoryTurns,
              maximumWorkspaceEmails: 24,
              maximumWorkspaceAgendaItems: 32
          )

          static let configured = Budget(
              maximumBodyCharacters: configuredBodyCharacters,
              maximumTextCharacters: configuredBodyCharacters,
              maximumEmails: configuredMaximumEmails,
              maximumHistoryTurns: configuredMaximumHistoryTurns,
              maximumWorkspaceEmails: 256,
              maximumWorkspaceAgendaItems: 128
          )
      }

      static let maximumCustomInstructionCharacters = 6_000
      ```

- [ ] Fazer `transform` usar o orçamento. Em `AssistantPrompt.transform` (linha 351 do arquivo original), trocar
      ```swift
      \(bounded(text, maximumCharacters: maximumTextCharacters))
      ```
      por
      ```swift
      \(bounded(text, maximumCharacters: budget.maximumTextCharacters))
      ```
      e, em `actionDescription`, passar o orçamento da instrução personalizada:
      ```swift
      static func actionDescription(_ action: WritingAction) -> String {
          switch action {
          // … casos inalterados …
          case let .customInstruction(instruction):
              return "Aplique esta instrução personalizada sem violar as regras acima:\n"
                  + bounded(instruction, maximumCharacters: maximumCustomInstructionCharacters)
          }
      }
      ```

- [ ] Fazer o retrato do ambiente usar o orçamento. Trocar a assinatura privada por uma interna e propagar:
      ```swift
      private static func mailContext(_ context: AssistantMailContext, budget: Budget) -> String {
          switch context {
          case let .email(email):
              return render(email, index: 1, budget: budget)
          case let .conversation(emails):
              let omitted = max(0, emails.count - budget.maximumEmails)
              let latestEmails = emails.suffix(budget.maximumEmails)
              let marker = omitted > 0
                  ? "[\(omitted) e-mail(s) anterior(es) removido(s) para caber no contexto.]\n"
                  : ""
              return marker + latestEmails.enumerated().map { offset, email in
                  render(email, index: omitted + offset + 1, budget: budget)
              }.joined(separator: "\n")
          case let .workspace(workspace):
              return render(workspace, budget: budget)
          }
      }

      static func render(_ workspace: AssistantWorkspaceContext, budget: Budget) -> String {
          // … início inalterado (contas e caixas) …
          let detailedEmails = workspace.emails.prefix(budget.maximumWorkspaceEmails)
          // … inalterado …
          let agendaItems = workspace.agenda.prefix(budget.maximumWorkspaceAgendaItems)
          // … resto inalterado …
      }
      ```
      `maximumWorkspaceEmails` e `maximumWorkspaceAgendaItems` deixam de ser constantes do tipo (linhas 176 e 178) e são apagadas; quem quiser o número lê do `Budget`.

- [ ] Criar a fábrica de sessão. `Packages/UNISync/Sources/UNISync/AssistantURLSessionFactory.swift`:
      ```swift
      import Foundation

      /// `URLRequest.timeoutInterval` só cobre a espera entre pacotes. Um prompt
      /// de 400 mil caracteres com resposta longa estoura o **recurso**, não o
      /// pedido — e o dono já viu o Grok morrer assim. Os dois tempos são
      /// gravados juntos, uma vez, na sessão que o roteador guarda.
      enum AssistantURLSessionFactory {
          static func timed(basedOn session: URLSession, timeout: TimeInterval) -> URLSession {
              // `session.configuration` devolve uma cópia; mutá-la não afeta a
              // sessão de origem e preserva `protocolClasses`, que é o que
              // mantém os testes com StubURLProtocol valendo.
              let configuration = session.configuration
              configuration.timeoutIntervalForRequest = timeout
              configuration.timeoutIntervalForResource = timeout
              return URLSession(configuration: configuration, delegate: nil, delegateQueue: nil)
          }
      }
      ```

- [ ] Trocar os tempos no roteador. Em `AssistantRouter.swift`, no `init` (linhas 34–57):
      ```swift
      public init(
          settingsStore: AssistantSettingsStore,
          credentialStore: any AssistantCredentialStore,
          session: URLSession = .shared,
          requestTimeout: TimeInterval = 120,
          oauthTokenProvider: (any OpenAICompatibleOAuthTokenProviding)? = nil,
          providerOAuthTokenProvider: (any AssistantProviderOAuthTokenProviding)? = nil,
          cliInstallationProvider: @escaping @Sendable () -> [AssistantCLIInstallation] = {
              AssistantCLIDiscovery().scan()
          },
          cliExecutor: any AssistantCLIProcessExecuting = SystemAssistantCLIProcessExecutor(),
          cliRequestTimeout: TimeInterval = 120
      ) {
          self.settingsStore = settingsStore
          self.credentialStore = credentialStore
          self.requestTimeout = max(1, requestTimeout)
          self.session = AssistantURLSessionFactory.timed(
              basedOn: session,
              timeout: max(self.requestTimeout, 120)
          )
          self.oauthTokenProvider = oauthTokenProvider
          self.providerOAuthTokenProvider = providerOAuthTokenProvider
          self.cliInstallationProvider = cliInstallationProvider
          self.cliExecutor = cliExecutor
          // Faixa da spec 1.4: nunca menos de 30 s (um CLI frio demora a subir),
          // nunca mais de 300 s (o botão precisa devolver a mão da pessoa).
          self.cliRequestTimeout = min(max(cliRequestTimeout, 30), 300)
      }
      ```

- [ ] Ampliar a faixa do CLI. Em `AssistantCLITextAssistant.swift`, `init` (linha 457) passa a `requestTimeout: TimeInterval = 120` e a linha 462 vira:
      ```swift
      self.requestTimeout = min(max(requestTimeout, 30), 300)
      ```

- [ ] Rodar e ver passar:
      ```bash
      swift test --package-path Packages/UNISync
      ```
      Esperado: suíte verde. Se `FoundationModelsTextAssistantTests` (agora `AssistantPromptTests`) tinha uma asserção travando `maximumWorkspaceEmails` como constante do tipo, atualize-a para `AssistantPrompt.Budget.onDevice.maximumWorkspaceEmails`.

- [ ] Provar por mutação: volte `budget.maximumTextCharacters` para `maximumTextCharacters` em `transform` e confirme que `configuredTransformKeepsLongText` falha; desfaça. Volte `budget.maximumWorkspaceEmails` para `24` e confirme que `workspaceRespectsBudget` falha; desfaça.

- [ ] Commit:
      ```bash
      git add -A && git commit -m "fix: o orçamento atravessa transform e o retrato do ambiente

Timeout de 30 s era errado para prompt de 400 mil caracteres, e
render(workspace) ignorava o Budget cravando 24/32. Spec 1.4.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
      ```

---

### Task 5: O idioma das preferências sempre vence (spec 1.4)

`generatedInstructions()` só emite a linha de idioma quando ele **não** é pt-BR (`AssistantSettings.swift:418`), e o prompt de `answer` abre com "Responda à pergunta atual em português do Brasil" (`FoundationModelsTextAssistant.swift:283`) — depois da camada de instruções. A preferência nunca vence.

**Files**
- Modify `Packages/UNISync/Sources/UNISync/AssistantSettings.swift` (`generatedInstructions()` em `:414-424`)
- Modify `Packages/UNISync/Sources/UNISync/FoundationModelsTextAssistant.swift` (`answer` em `:277-306`; `transform` em `:308-330`)
- Create `Packages/UNISync/Tests/UNISyncTests/AssistantBehaviorPreferencesTests.swift`

**Interfaces**
- Produces: `AssistantBehaviorPreferences.generatedInstructions() -> String` passa a emitir a linha de idioma em todos os casos.

**Steps**

- [ ] Escrever o teste que falha. `Packages/UNISync/Tests/UNISyncTests/AssistantBehaviorPreferencesTests.swift`:
      ```swift
      import Foundation
      import Testing
      @testable import UNISync

      @Suite("Preferências de comportamento do assistente")
      struct AssistantBehaviorPreferencesTests {
          @Test("inglês não produz a palavra português em lugar nenhum do prompt")
          func englishNeverMentionsPortuguese() {
              let settings = AssistantSettings(
                  provider: .openAICompatible,
                  behavior: .init(language: .english)
              )
              let instructions = settings.configuredInstructions(for: .questions)
              #expect(instructions.contains("Respond in English."))
              #expect(!instructions.lowercased().contains("português"))

              let prompt = AssistantPrompt.answer(
                  question: "What is urgent?",
                  conversation: .init(mailContext: .workspace(.init(
                      accounts: [], emailCount: 0, unreadCount: 0,
                      mailboxes: [], emails: [], agenda: []
                  ))),
                  budget: .configured
              )
              #expect(!prompt.lowercased().contains("português"))

              let writing = AssistantPrompt.transform(
                  text: "Please review.",
                  action: .summarize,
                  context: nil,
                  budget: .configured
              )
              #expect(!writing.lowercased().contains("português"))
          }

          @Test("português do Brasil também é emitido: o padrão deixou de ser implícito")
          func portugueseIsEmittedToo() {
              let settings = AssistantSettings(behavior: .init(language: .portugueseBrazil))
              #expect(settings.configuredInstructions(for: .writing)
                  .contains("Responda em português do Brasil."))
          }
      }
      ```

- [ ] Rodar e ver falhar:
      ```bash
      swift test --package-path Packages/UNISync --filter AssistantBehaviorPreferencesTests
      ```
      Esperado: duas falhas — `portugueseIsEmittedToo` porque a linha é suprimida, e `englishNeverMentionsPortuguese` porque `AssistantPrompt.answer` começa com "em português do Brasil".

- [ ] Sempre emitir o idioma. Em `AssistantSettings.swift`, dentro de `generatedInstructions()`, trocar a linha 418
      ```swift
      if language != .portugueseBrazil { instructions.append(language.promptInstruction) }
      ```
      por
      ```swift
      // Sem condição: enquanto pt-BR era o silêncio, a preferência da pessoa
      // perdia para a linha fixa do prompt, que dizia português sempre.
      instructions.append(language.promptInstruction)
      ```

- [ ] Tirar o idioma do prompt fixo. Em `AssistantPrompt.answer`, a abertura (linhas 283–284) vira:
      ```swift
      Responda à pergunta atual com a profundidade que ela exigir. Comece pela
      resposta mais útil.
      ```
      E em `AssistantPrompt.transform`, os dois `languageInstruction` que cravam pt-BR (linhas 326 e 329) viram:
      ```swift
      case .customInstruction:
          usesMailContext = true
          languageInstruction = "Execute a tarefa de escrita abaixo."
      default:
          usesMailContext = false
          languageInstruction = "Execute a tarefa de escrita abaixo."
      ```
      O caso `.draftReply` **não muda**: responder em português a uma mensagem em inglês é o defeito que aquela regra conserta, e ela é sobre o idioma da conversa, não sobre a preferência.

- [ ] Rodar e ver passar:
      ```bash
      swift test --package-path Packages/UNISync
      ```
      Esperado: suíte verde. Testes antigos que afirmavam a ausência da linha de idioma para pt-BR precisam ser invertidos — a ausência era o defeito.

- [ ] Provar por mutação: recoloque o `if language != .portugueseBrazil` e confirme que `portugueseIsEmittedToo` falha; desfaça.

- [ ] Commit:
      ```bash
      git add -A && git commit -m "fix: a preferência de idioma vence o prompt fixo

A linha só era emitida fora de pt-BR e o prompt de answer abria em
português. Agora o idioma sai sempre das preferências. Spec 1.4.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
      ```

---

### Task 6: `AssistantFailure` e `AssistantFailureBand` (spec 1.5)

Quatro enums de erro achatadas em `localizedDescription`, sem ação de recuperação (`LocalAssistantPanel.swift:267-274`, `DashboardScreen.swift:774-777`). Uma tradução só, uma faixa só. Vem **antes** da máquina de estado porque é ela que guarda `failure`.

**Files**
- Create `Packages/UNIShell/Sources/UNIShell/Support/AssistantFailure.swift`
- Create `Packages/UNIShell/Tests/UNIShellTests/AssistantFailureTests.swift`

**Interfaces**
- Consumes (UNISync): `TextAssistantError` (UNICore), `OpenAICompatibleTextAssistantError` (`OpenAICompatibleTextAssistant.swift:6`), `AssistantProviderOAuthTextAssistantError` (`AssistantProviderOAuthTextAssistant.swift:6`), `AssistantCLITextAssistantError` (`AssistantCLITextAssistant.swift:301`), `AssistantProviderOAuthError` (`AssistantProviderOAuthClient.swift:5`), `AssistantSettingsError` (`AssistantSettings.swift:30`), `AssistantProviderOAuthKind` (`AssistantSettings.swift:193`).
- Produces:
  ```swift
  public struct AssistantFailure: Sendable, Hashable {
      public enum Recovery: Sendable, Hashable {
          case retry
          case openSettings
          case reconnect(AssistantProviderOAuthKind)
      }
      public let message: String
      public let recovery: Recovery?
      public init(message: String, recovery: Recovery?)
      public init(_ error: any Error)
  }

  struct AssistantFailureBand: View {
      let failure: AssistantFailure
      var onRetry: () -> Void = {}
      var onOpenSettings: () -> Void = {}
  }
  ```

**Steps**

- [ ] Escrever o teste que falha. `Packages/UNIShell/Tests/UNIShellTests/AssistantFailureTests.swift`:
      ```swift
      import Foundation
      import Testing
      import UNICore
      import UNISync
      @testable import UNIShell

      @Suite("Tradução de falhas do assistente")
      struct AssistantFailureTests {
          @Test("credencial ausente manda para os Ajustes, não para 'tentar de novo'")
          func missingCredentialsOpenSettings() {
              #expect(AssistantFailure(OpenAICompatibleTextAssistantError.missingAPIKey).recovery == .openSettings)
              #expect(AssistantFailure(OpenAICompatibleTextAssistantError.missingOAuthAuthorization).recovery == .openSettings)
              #expect(AssistantFailure(AssistantCLITextAssistantError.executableNotFound(.codex)).recovery == .openSettings)
              #expect(AssistantFailure(AssistantSettingsError.missingModel).recovery == .openSettings)
          }

          @Test("sessão recusada pede reconexão do provedor certo")
          func authenticationAsksForReconnect() {
              #expect(AssistantFailure(AssistantProviderOAuthTextAssistantError.authenticationFailed).recovery == nil)
              #expect(AssistantFailure(AssistantProviderOAuthError.missingSession).recovery == nil)
              // A reconexão só sabe o provedor quando quem traduz o informa.
              let grok = AssistantFailure(
                  AssistantProviderOAuthTextAssistantError.authenticationFailed,
                  provider: .xAI
              )
              #expect(grok.recovery == .reconnect(.xAI))
              #expect(grok.message == AssistantProviderOAuthTextAssistantError.authenticationFailed.errorDescription)
          }

          @Test("erro temporário oferece tentar de novo")
          func transientErrorsRetry() {
              #expect(AssistantFailure(OpenAICompatibleTextAssistantError.timedOut).recovery == .retry)
              #expect(AssistantFailure(OpenAICompatibleTextAssistantError.rateLimited).recovery == .retry)
              #expect(AssistantFailure(OpenAICompatibleTextAssistantError.connectionFailed).recovery == .retry)
              #expect(AssistantFailure(AssistantCLITextAssistantError.timedOut).recovery == .retry)
              #expect(AssistantFailure(TextAssistantError.emptyResponse).recovery == .retry)
              #expect(AssistantFailure(TextAssistantError.emptyResponse).message
                  == "O assistente devolveu uma resposta vazia.")
          }

          @Test("o CLI que morreu mostra a primeira linha do stderr")
          func cliFailureShowsStderr() {
              let failure = AssistantFailure(AssistantCLITextAssistantError.processFailed(
                  exitCode: 2,
                  stderrTail: "error: not logged in\nrun `codex login`"
              ))
              #expect(failure.message.contains("error: not logged in"))
              #expect(!failure.message.contains("codex login"))
              #expect(failure.recovery == .openSettings)
          }

          @Test("erro sem descrição aproveitável não vira frase vazia")
          func unknownErrorHasCopy() {
              struct Silencioso: Error {}
              let failure = AssistantFailure(Silencioso())
              #expect(!failure.message.isEmpty)
              #expect(failure.recovery == .retry)
          }
      }
      ```

- [ ] Rodar e ver falhar:
      ```bash
      swift test --package-path Packages/UNIShell --filter AssistantFailureTests
      ```
      Esperado: `cannot find 'AssistantFailure' in scope` e, depois de existir, `processFailed(exitCode:stderrTail:)` inexistente (a Task 11 traz o stderr; **antecipe só a assinatura** do caso na Task 11 se quiser rodar este teste isolado — este passo assume a ordem do plano e deixa `cliFailureShowsStderr` marcado com `.disabled("stderr chega na Task 11")` até lá).

- [ ] Implementar. `Packages/UNIShell/Sources/UNIShell/Support/AssistantFailure.swift`:
      ```swift
      import SwiftUI
      import UNICore
      import UNIDesign
      import UNISync

      /// A tradução única de qualquer `Error` do assistente para o que a pessoa
      /// lê e para o que ela pode fazer a respeito.
      ///
      /// Os quatro enums de adaptador ficam como estão: cada um sabe do seu
      /// transporte. O que não podia continuar é cada superfície inventar a sua
      /// própria frase a partir de `localizedDescription`, sem oferecer saída.
      public struct AssistantFailure: Sendable, Hashable {
          public enum Recovery: Sendable, Hashable {
              case retry
              case openSettings
              case reconnect(AssistantProviderOAuthKind)
          }

          public let message: String
          public let recovery: Recovery?

          public init(message: String, recovery: Recovery?) {
              self.message = message
              self.recovery = recovery
          }

          /// `provider` só é conhecido quando quem chama sabe qual assinatura
          /// está configurada; sem ele, um 401 vira "tentar de novo" em vez de
          /// mandar reconectar uma conta que talvez nem seja a certa.
          public init(_ error: any Error, provider: AssistantProviderOAuthKind? = nil) {
              switch error {
              case let error as TextAssistantError:
                  self.init(
                      message: error.errorDescription ?? Self.fallbackMessage,
                      recovery: {
                          switch error {
                          case .unavailable, .invalidRequest: .openSettings
                          case .emptyResponse, .generationFailed: .retry
                          }
                      }()
                  )
              case let error as OpenAICompatibleTextAssistantError:
                  self.init(
                      message: error.errorDescription ?? Self.fallbackMessage,
                      recovery: {
                          switch error {
                          case .missingAPIKey, .missingOAuthAuthorization,
                               .oauthProviderUnavailable, .authenticationFailed:
                              .openSettings
                          case .rateLimited, .timedOut, .connectionFailed,
                               .server, .invalidResponse:
                              .retry
                          }
                      }()
                  )
              case let error as AssistantProviderOAuthTextAssistantError:
                  self.init(
                      message: error.errorDescription ?? Self.fallbackMessage,
                      recovery: {
                          switch error {
                          case .missingAuthorization, .authenticationFailed,
                               .subscriptionNotEligible, .managedByCodexRuntime:
                              provider.map(Recovery.reconnect)
                          case .rateLimited, .timedOut, .connectionFailed,
                               .redirectRefused, .upgradeRequired,
                               .server, .invalidResponse:
                              .retry
                          }
                      }()
                  )
              case let error as AssistantProviderOAuthError:
                  self.init(
                      message: error.errorDescription ?? Self.fallbackMessage,
                      recovery: {
                          switch error {
                          case .missingSession, .sessionProviderMismatch,
                               .authorizationDenied, .authorizationExpired,
                               .invalidTokenResponse:
                              provider.map(Recovery.reconnect)
                          default:
                              .retry
                          }
                      }()
                  )
              case let error as AssistantCLITextAssistantError:
                  self.init(
                      message: Self.cliMessage(error),
                      recovery: {
                          switch error {
                          case .executableNotFound, .executableNotAllowed, .processFailed:
                              .openSettings
                          case .timedOut, .outputTooLarge, .invalidResponse:
                              .retry
                          }
                      }()
                  )
              case let error as AssistantSettingsError:
                  self.init(
                      message: error.errorDescription ?? Self.fallbackMessage,
                      recovery: .openSettings
                  )
              case let error as MessageAnalysisError:
                  self.init(
                      message: error.errorDescription ?? Self.fallbackMessage,
                      recovery: .retry
                  )
              default:
                  let described = (error as? any LocalizedError)?.errorDescription?
                      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                  self.init(
                      message: described.isEmpty ? Self.fallbackMessage : described,
                      recovery: .retry
                  )
              }
          }

          /// O stderr do CLI é o único lugar onde a causa real aparece ("not
          /// logged in", "model not found"). Uma linha basta: a cauda inteira é
          /// ruído e pode carregar caminho de arquivo da pessoa.
          private static func cliMessage(_ error: AssistantCLITextAssistantError) -> String {
              let base = error.errorDescription ?? fallbackMessage
              guard case let .processFailed(_, stderrTail) = error else { return base }
              let firstLine = stderrTail
                  .split(separator: "\n", omittingEmptySubsequences: true)
                  .first
                  .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
              guard !firstLine.isEmpty else { return base }
              return "\(base) \(firstLine)"
          }

          static let fallbackMessage = "Não foi possível responder agora."
      }
      ```
      E, no mesmo arquivo, a faixa que painel e dashboard compartilham:
      ```swift
      /// A faixa única de erro. Painel, dashboard e janela de mensagem mostram
      /// esta, e nenhuma tem cópia própria.
      struct AssistantFailureBand: View {
          @Environment(\.theme) private var theme
          @Environment(\.displayScale) private var displayScale

          let failure: AssistantFailure
          var onRetry: () -> Void = {}
          var onOpenSettings: () -> Void = {}

          var body: some View {
              VStack(alignment: .leading, spacing: 8) {
                  HStack(spacing: 7) {
                      Image(systemName: "exclamationmark.triangle")
                          .font(.system(size: 12, weight: .semibold))
                          .foregroundStyle(theme.ink3.color)
                          .accessibilityHidden(true)
                      Text(failure.message)
                          .font(theme.sans.font(size: 12, weight: .semibold))
                          .foregroundStyle(theme.ink2.color)
                          .fixedSize(horizontal: false, vertical: true)
                  }
                  switch failure.recovery {
                  case .retry:
                      ChromeButton("Tentar de novo", appearance: .outlined,
                                   size: 11.5, height: 27, horizontalPadding: 10,
                                   action: onRetry)
                          .help("Repete o último pedido ao assistente")
                  case .openSettings:
                      ChromeButton("Abrir Ajustes", appearance: .outlined,
                                   size: 11.5, height: 27, horizontalPadding: 10,
                                   action: onOpenSettings)
                          .help("Abre Configurações para escolher ou corrigir o provedor")
                  case let .reconnect(kind):
                      ChromeButton("Reconectar \(kind == .codex ? "ChatGPT" : "xAI")",
                                   appearance: .outlined,
                                   size: 11.5, height: 27, horizontalPadding: 10,
                                   action: onOpenSettings)
                          .help("Abre Configurações para entrar de novo na assinatura")
                  case nil:
                      EmptyView()
                  }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(11)
              .background(theme.surface3.color)
              .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
              .overlay {
                  RoundedRectangle(cornerRadius: theme.radiusSmall)
                      .strokeBorder(theme.line2.color, lineWidth: Hairline.thickness(displayScale))
              }
              .accessibilityElement(children: .combine)
              .accessibilityIdentifier("assistant-failure-band")
          }
      }
      ```
      Confira a assinatura real de `ChromeButton` em `Packages/UNIShell/Sources/UNIShell/Windows/ChromeButton.swift` antes de compilar — o uso atual no painel é `ChromeButton("Tentar de novo", appearance: .outlined, size: 11.5, height: 27, horizontalPadding: 10) { … }` (`AssistantPanel.swift:547-552`); use exatamente essa forma.

- [ ] Rodar e ver passar:
      ```bash
      swift test --package-path Packages/UNIShell --filter AssistantFailureTests
      ```
      Esperado: `✔ Test run with 5 tests in 1 suite passed` (com `cliFailureShowsStderr` ainda desabilitado até a Task 11).

- [ ] Provar por mutação: troque `.openSettings` por `.retry` no ramo de `missingAPIKey` e confirme que `missingCredentialsOpenSettings` falha; desfaça.

- [ ] Commit:
      ```bash
      git add -A && git commit -m "feat: AssistantFailure traduz qualquer erro do assistente uma vez só

Quatro enums de adaptador, uma mensagem e uma recuperação. A faixa é a
mesma no painel e no dashboard. Spec 1.5.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
      ```

---

### Task 7: `AssistantMarkdown` sai do popover (spec 1.7)

Markdown só é renderizado em `ReaderIntelligencePopover` (`ReaderAssistantMarkdownBlock` em `:653`, `ReaderAssistantMarkdown` em `:732`); painel e dashboard mostram `Text` cru (`AssistantPanel.swift:509`, `DashboardScreen.swift:430`).

**Files**
- Create `Packages/UNIShell/Sources/UNIShell/Support/AssistantMarkdown.swift` (recorte de `ReaderIntelligencePopover.swift:651-792`)
- Modify `Packages/UNIShell/Sources/UNIShell/Inbox/ReaderIntelligencePopover.swift` (apagar as duas definições; a chamada em `:344` continua igual, só muda o nome do tipo)
- Create `Packages/UNIShell/Tests/UNIShellTests/AssistantMarkdownTests.swift`
- Modify `Packages/UNIShell/Tests/UNIShellTests/` — o conjunto que hoje testa `ReaderAssistantMarkdownBlock.parse` (procure com `git grep -l ReaderAssistantMarkdownBlock -- Packages/UNIShell/Tests`) passa a citar `AssistantMarkdownBlock`

**Interfaces**
- Produces:
  ```swift
  struct AssistantMarkdownBlock: Identifiable, Equatable, Sendable {
      enum Kind: Equatable, Sendable {
          case paragraph(String), heading(String), bullet(String)
          case numbered(marker: String, text: String)
      }
      let id: Int
      let kind: Kind
      nonisolated static func parse(_ text: String) -> [Self]
  }

  struct AssistantMarkdown: View {
      let text: String
      /// Turno `kind: .draft` é prosa de email: asterisco ali é literal.
      init(text: String)
  }
  ```

**Steps**

- [ ] Escrever o teste que falha. `Packages/UNIShell/Tests/UNIShellTests/AssistantMarkdownTests.swift`:
      ```swift
      import AppKit
      import Foundation
      import SwiftUI
      import Testing
      import UNIDesign
      @testable import UNIShell

      @Suite("Markdown do assistente")
      @MainActor
      struct AssistantMarkdownTests {
          @Test("listas, títulos e numeração viram blocos separados")
          func parsesBlocks() {
              let blocks = AssistantMarkdownBlock.parse("""
              ## Pendências
              - responder Marina
              2. confirmar sala

              Parágrafo final.
              """)
              #expect(blocks.count == 4)
              #expect(blocks[0].kind == .heading("Pendências"))
              #expect(blocks[1].kind == .bullet("responder Marina"))
              #expect(blocks[2].kind == .numbered(marker: "2.", text: "confirmar sala"))
              #expect(blocks[3].kind == .paragraph("Parágrafo final."))
          }

          @Test("o painel renderiza a resposta do assistente como Markdown")
          func panelRendersMarkdown() async throws {
              let image = try #require(Render.snapshot(
                  AssistantMarkdown(text: "- um\n- dois")
                      .frame(width: 300)
                      .environment(ThemeStore()),
                  named: "assistant-markdown",
                  size: CGSize(width: 300, height: 120),
                  theme: .okami
              ))
              #expect(image.pixelsWide == 300)
          }
      }
      ```

- [ ] Rodar e ver falhar:
      ```bash
      swift test --package-path Packages/UNIShell --filter AssistantMarkdownTests
      ```
      Esperado: `cannot find 'AssistantMarkdownBlock' in scope`.

- [ ] Mover o código. Criar `Support/AssistantMarkdown.swift` com o conteúdo integral de `ReaderIntelligencePopover.swift:651-792`, renomeando `ReaderAssistantMarkdownBlock` → `AssistantMarkdownBlock` e `ReaderAssistantMarkdown` → `AssistantMarkdown`, e trocando `private struct ReaderAssistantMarkdown` por `struct AssistantMarkdown` (deixa de ser `private` porque painel, dashboard e janela de mensagem passam a usá-lo). Apagar as duas definições do popover.

- [ ] Propagar o nome:
      ```bash
      perl -pi -e '
        s/\bReaderAssistantMarkdownBlock\b/AssistantMarkdownBlock/g;
        s/\bReaderAssistantMarkdown\b/AssistantMarkdown/g;
      ' $(git ls-files 'Packages/UNIShell/**/*.swift')
      git grep -n ReaderAssistantMarkdown -- '*.swift' || echo "nome antigo eliminado"
      ```

- [ ] Adotar no painel. Em `Packages/UNIShell/Sources/UNIShell/Inbox/AssistantPanel.swift`, dentro de `messageBubble` (linha 509), trocar
      ```swift
      Text(message.text)
          .font(theme.sans.font(size: 12.5))
          .foregroundStyle(theme.ink2.color)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      ```
      por
      ```swift
      // Turno de rascunho é prosa de email: asterisco e hífen ali são
      // literais que a pessoa vai colar no composer.
      if message.kind == .draft || message.speaker == .user {
          Text(message.text)
              .font(theme.sans.font(size: 12.5))
              .foregroundStyle(theme.ink2.color)
              .fixedSize(horizontal: false, vertical: true)
              .textSelection(.enabled)
      } else {
          AssistantMarkdown(text: message.text)
      }
      ```
      (`message.kind` chega na Task 8; até lá use só `message.speaker == .user` e complete a condição naquela tarefa.)

- [ ] Rodar e ver passar:
      ```bash
      swift test --package-path Packages/UNIShell
      ```
      Esperado: suíte verde, inclusive os conjuntos do popover que já testavam o parser.

- [ ] Commit:
      ```bash
      git add -A && git commit -m "refactor: AssistantMarkdown sai do popover para o Support

Painel e dashboard mostravam Text cru; a mesma resposta virava lista no
leitor e parágrafo colado no painel. Spec 1.7.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
      ```

---

### Task 8: `AssistantConversation`, a única máquina de estado (spec 1.3)

Hoje existem duas: a do painel (`AssistantPanel.swift:184-276`) e a reimplementada em `DashboardScreen.run/runDraft/runSuggestion` (`:728-778`). Nenhuma cancela; nenhuma tem `Task` guardado; o rascunho do dashboard vai por `answer()`, cujo prompt pede Markdown, e volta com `**` e listas.

> **Desvio consciente da spec, forçado pelo Swift:** a spec pede `func briefing()` (§1.3) **e** `AssistantConversation.briefing: String?` (§2.5). Swift recusa: `invalid redeclaration of 'briefing()'` (conferido com `swiftc`). O método fica com o nome da spec; a propriedade vira `briefingText: String?`.

**Files**
- Create `Packages/UNIShell/Sources/UNIShell/Inbox/AssistantConversation.swift`
- Modify `Packages/UNIShell/Sources/UNIShell/Inbox/AssistantPanel.swift` (apagar a classe das linhas 184–276; mover `AssistantMessage`, `AssistantSpeaker`, `AssistantRequest` e `AssistantPanelDebugState` para o arquivo novo; o `AssistantPanel` passa a **receber** a conversa)
- Modify `Packages/UNIShell/Sources/UNIShell/Support/AssistantBridge.swift` (fábrica do motor)
- Create `Packages/UNIShell/Tests/UNIShellTests/AssistantConversationTests.swift`

**Interfaces**
- Consumes: `TextAssisting`, `AssistantMailContext`, `WritingAction.draftReply`, `TextAssistantError` (UNICore); `AssistantDestination` (Task 3); `AssistantFailure` (Task 6).
- Produces:
  ```swift
  public enum AssistantTurnKind: String, Sendable, Hashable { case message, draft }

  public struct AssistantMessage: Identifiable, Sendable, Hashable {
      public let id: UUID
      public let speaker: AssistantSpeaker
      public let text: String
      public let kind: AssistantTurnKind
      public init(id: UUID = UUID(), speaker: AssistantSpeaker, text: String, kind: AssistantTurnKind = .message)
  }

  @MainActor
  public struct AssistantEngine {
      public let supportsDraftReply: Bool
      public let answer: (AssistantRequest) async throws -> String
      public let draftReply: (AssistantRequest) async throws -> String
  }

  @MainActor @Observable
  public final class AssistantConversation {
      public static let maximumHistoryTurns = 16
      public static let summaryQuestion: String
      public static let briefingQuestion: String

      public private(set) var messages: [AssistantMessage]
      public var draft: String
      public private(set) var isLoading: Bool
      public private(set) var failure: AssistantFailure?
      public private(set) var briefingText: String?

      public let scope: AssistantScope
      public let context: AssistantContext
      public let destination: AssistantDestination

      public var canSend: Bool
      public var canDraftReply: Bool
      public var canRetry: Bool
      public var hasConversation: Bool

      public func ask(_ question: String)
      public func submit()
      public func run(_ suggestion: AssistantSuggestion)
      public func draftReply()
      public func summarize()
      public func briefing()
      public func cancel()
      public func clear()
      public func retry()
  }

  public extension AssistantBridge {
      @MainActor
      static func engine(
          using assistant: any TextAssisting,
          supportsDraftReply: Bool,
          mailContext: @escaping @MainActor () async throws -> AssistantMailContext
      ) -> AssistantEngine
  }
  ```

**Steps**

- [ ] Escrever os testes que falham. `Packages/UNIShell/Tests/UNIShellTests/AssistantConversationTests.swift`:
      ```swift
      import Foundation
      import Testing
      import UNICore
      import UNISync
      @testable import UNIShell

      /// Espião do contrato puro. Guarda o que foi pedido e devolve o que o
      /// teste mandar, sem tocar em FoundationModels nem em rede.
      final class SpyTextAssistant: TextAssisting, @unchecked Sendable {
          struct TransformCall: Equatable {
              let text: String
              let action: WritingAction
          }

          let modelVersion = "spy/v1"
          var answerResult: Result<String, any Error> = .success("resposta")
          var transformResult: Result<String, any Error> = .success("Oi Marina,\n\nFechado.")
          private(set) var answers: [AssistantConversationSnapshot] = []
          private(set) var transforms: [TransformCall] = []
          var beforeAnswer: (@Sendable () async -> Void)?

          func availability() async -> AppleIntelligenceAvailability { .available }

          func answer(question: String, in conversation: AssistantConversationSnapshot) async throws -> String {
              answers.append(conversation)
              await beforeAnswer?()
              return try answerResult.get()
          }

          func transform(_ text: String, using action: WritingAction, context: AssistantMailContext?) async throws -> String {
              transforms.append(.init(text: text, action: action))
              return try transformResult.get()
          }
      }

      @Suite("Máquina de estado do assistente")
      @MainActor
      struct AssistantConversationTests {
          private let emailContext = AssistantMailContext.email(
              AssistantEmailContext(subject: "Revisão", sender: "marina@example.com", body: "Podemos amanhã?")
          )
          private let destination = AssistantDestination(
              label: "Grok · xAI", detail: "Sai deste Mac para a xAI.", isLocal: false
          )

          private func conversation(
            _ spy: SpyTextAssistant,
            scope: AssistantScope = .email
          ) -> AssistantConversation {
              AssistantConversation(
                  scope: scope,
                  context: .init(subject: "Revisão", sender: "Marina"),
                  destination: destination,
                  engine: AssistantBridge.engine(
                      using: spy,
                      supportsDraftReply: scope == .email,
                      mailContext: { self.emailContext }
                  )
              )
          }

          @Test("draftReply usa transform(.draftReply), nunca answer")
          func draftReplyUsesTransform() async {
              let spy = SpyTextAssistant()
              let conversation = conversation(spy)
              conversation.draftReply()
              await conversation.waitForIdle()

              #expect(spy.transforms == [.init(text: "", action: .draftReply)])
              #expect(spy.answers.isEmpty)
              #expect(conversation.messages.count == 1)
              #expect(conversation.messages[0].speaker == .assistant)
              #expect(conversation.messages[0].kind == .draft)
              #expect(conversation.messages[0].text == "Oi Marina,\n\nFechado.")
              #expect(conversation.failure == nil)
          }

          @Test("no ambiente inteiro não existe rascunho")
          func workspaceHasNoDraftReply() {
              let conversation = conversation(SpyTextAssistant(), scope: .workspace)
              #expect(!conversation.canDraftReply)
          }

          @Test("cancelar durante uma pergunta deixa o estado ocioso e sem erro")
          func cancelLeavesIdle() async {
              let spy = SpyTextAssistant()
              let started = AsyncGate()
              spy.beforeAnswer = { await started.openAndWaitForever() }
              let conversation = conversation(spy)
              conversation.ask("O que é urgente?")
              await started.waitUntilOpen()
              #expect(conversation.isLoading)

              conversation.cancel()
              await conversation.waitForIdle()
              #expect(!conversation.isLoading)
              #expect(conversation.failure == nil)
          }

          @Test("o histórico enviado ao motor tem 16 turnos com 20 acumulados")
          func historyIsCappedAtSixteen() async {
              let spy = SpyTextAssistant()
              let conversation = conversation(spy)
              for index in 1...10 {
                  conversation.ask("pergunta \(index)")
                  await conversation.waitForIdle()
              }
              #expect(conversation.messages.count == 20)

              conversation.ask("pergunta 11")
              await conversation.waitForIdle()
              let sent = try! #require(spy.answers.last)
              // A pergunta atual tem campo próprio no contrato e é retirada do
              // histórico pela ponte; sobram 16 turnos anteriores.
              #expect(sent.turns.count == AssistantConversation.maximumHistoryTurns)
              #expect(sent.turns.last?.text == "resposta")
          }

          @Test("resposta vazia vira emptyResponse, e é a única cópia")
          func emptyResponseHasOneCopy() async {
              let spy = SpyTextAssistant()
              spy.answerResult = .success("   \n ")
              let conversation = conversation(spy)
              conversation.ask("O que é urgente?")
              await conversation.waitForIdle()

              #expect(conversation.failure?.message == TextAssistantError.emptyResponse.errorDescription)
              #expect(conversation.failure?.recovery == .retry)
              #expect(conversation.messages.count == 1)
          }

          @Test("briefing vive fora do transcript e só dispara por chamada")
          func briefingIsSeparate() async {
              let spy = SpyTextAssistant()
              spy.answerResult = .success("Hoje: responder Marina às 9h42.")
              let conversation = conversation(spy, scope: .workspace)
              #expect(conversation.briefingText == nil)

              conversation.briefing()
              await conversation.waitForIdle()
              #expect(conversation.briefingText == "Hoje: responder Marina às 9h42.")
              #expect(conversation.messages.isEmpty)
              #expect(spy.answers.count == 1)
          }

          @Test("retry repete a última ação, inclusive o rascunho")
          func retryRepeatsLastAction() async {
              let spy = SpyTextAssistant()
              spy.transformResult = .failure(OpenAICompatibleTextAssistantError.timedOut)
              let conversation = conversation(spy)
              conversation.draftReply()
              await conversation.waitForIdle()
              #expect(conversation.failure?.recovery == .retry)

              spy.transformResult = .success("Oi Marina,")
              conversation.retry()
              await conversation.waitForIdle()
              #expect(spy.transforms.count == 2)
              #expect(conversation.failure == nil)
              #expect(conversation.messages.last?.kind == .draft)
          }

          @Test("limpar apaga transcript, rascunho, erro e briefing")
          func clearResetsEverything() async {
              let spy = SpyTextAssistant()
              let conversation = conversation(spy, scope: .workspace)
              conversation.briefing()
              await conversation.waitForIdle()
              conversation.ask("e depois?")
              await conversation.waitForIdle()

              conversation.clear()
              #expect(conversation.messages.isEmpty)
              #expect(conversation.briefingText == nil)
              #expect(conversation.failure == nil)
              #expect(conversation.draft.isEmpty)
          }
      }

      /// Portão determinístico: nada de `Task.sleep` para sincronizar teste.
      actor AsyncGate {
          private var isOpen = false
          private var waiters: [CheckedContinuation<Void, Never>] = []

          func openAndWaitForever() async {
              isOpen = true
              for waiter in waiters { waiter.resume() }
              waiters.removeAll()
              await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
          }

          func waitUntilOpen() async {
              guard !isOpen else { return }
              await withCheckedContinuation { waiters.append($0) }
          }
      }
      ```
      E, no próprio `AssistantConversation.swift`, o auxiliar que os testes usam para esperar o `Task` guardado sem dormir:
      ```swift
      #if DEBUG
      public extension AssistantConversation {
          /// Espera o pedido em voo terminar. Existe para o teste não precisar
          /// de `Task.sleep`, que é o que transforma suíte em loteria.
          func waitForIdle() async { await currentTask?.value }
      }
      #endif
      ```

- [ ] Rodar e ver falhar:
      ```bash
      swift test --package-path Packages/UNIShell --filter AssistantConversationTests
      ```
      Esperado: `cannot find 'AssistantEngine' in scope`, `extra argument 'scope' in call`, `value of type 'AssistantConversation' has no member 'draftReply'`.

- [ ] Implementar a máquina. `Packages/UNIShell/Sources/UNIShell/Inbox/AssistantConversation.swift`:
      ```swift
      import Foundation
      import Observation
      import UNICore
      import UNISync

      /// Se um turno é conversa ou prosa de email. Um rascunho não passa pelo
      /// renderizador de Markdown: asterisco ali é literal.
      public enum AssistantTurnKind: String, Sendable, Hashable {
          case message
          case draft
      }

      public enum AssistantSpeaker: String, Sendable, Hashable {
          case user
          case assistant
      }

      public struct AssistantMessage: Identifiable, Sendable, Hashable {
          public let id: UUID
          public let speaker: AssistantSpeaker
          public let text: String
          public let kind: AssistantTurnKind

          public init(
              id: UUID = UUID(),
              speaker: AssistantSpeaker,
              text: String,
              kind: AssistantTurnKind = .message
          ) {
              self.id = id
              self.speaker = speaker
              self.text = text
              self.kind = kind
          }
      }

      /// A entrada entregue ao motor por uma fiação externa ao shell.
      public struct AssistantRequest: Sendable, Hashable {
          public let context: AssistantContext
          public let question: String
          public let conversation: [AssistantMessage]

          public init(context: AssistantContext, question: String, conversation: [AssistantMessage]) {
              self.context = context
              self.question = question
              self.conversation = conversation
          }
      }

      /// As duas rotas que o assistente tem. Separá-las é o conserto: o
      /// dashboard mandava "escreva um rascunho" por `answer()`, cujo prompt
      /// pede Markdown, e o rascunho voltava com asteriscos e listas.
      @MainActor
      public struct AssistantEngine {
          public let supportsDraftReply: Bool
          public let answer: (AssistantRequest) async throws -> String
          public let draftReply: (AssistantRequest) async throws -> String

          public init(
              supportsDraftReply: Bool,
              answer: @escaping (AssistantRequest) async throws -> String,
              draftReply: @escaping (AssistantRequest) async throws -> String = { _ in
                  throw TextAssistantError.invalidRequest("Criar uma resposta requer contexto de e-mail.")
              }
          ) {
              self.supportsDraftReply = supportsDraftReply
              self.answer = answer
              self.draftReply = draftReply
          }
      }

      /// Estado construível para previews e renderização fora da tela.
      public struct AssistantPanelDebugState: Sendable, Hashable {
          public var messages: [AssistantMessage]
          public var draft: String
          public var isLoading: Bool
          public var failure: AssistantFailure?
          public var briefingText: String?

          public init(
              messages: [AssistantMessage] = [],
              draft: String = "",
              isLoading: Bool = false,
              failure: AssistantFailure? = nil,
              briefingText: String? = nil
          ) {
              self.messages = messages
              self.draft = draft
              self.isLoading = isLoading
              self.failure = failure
              self.briefingText = briefingText
          }

          public static let empty = AssistantPanelDebugState()
      }

      /// A única dona de transcript, `isLoading`, `failure` e `task`.
      ///
      /// Painel, dashboard, janela de mensagem e popover do leitor recebem uma
      /// instância por injeção. Antes havia duas máquinas de estado com regras
      /// diferentes para a mesma pergunta, e nenhuma delas cancelava nada.
      @MainActor
      @Observable
      public final class AssistantConversation {
          /// Vale em toda superfície. Antes o painel mandava tudo e o dashboard
          /// mandava 16 — a mesma conversa custava preços diferentes.
          public static let maximumHistoryTurns = 16

          public static let summaryQuestion =
              "Faça um resumo útil desta conversa, destacando o que importa."

          /// A pergunta fixa do briefing (spec §2.5). É constante para o
          /// resultado ser comparável entre dias e provedores.
          public static let briefingQuestion = """
              Faça um briefing do meu dia em até 120 palavras: o que exige \
              resposta hoje, os compromissos de hoje em ordem, e o que pode \
              esperar. Cite remetentes e horários.
              """

          public private(set) var messages: [AssistantMessage]
          public var draft: String
          public private(set) var isLoading: Bool
          public private(set) var failure: AssistantFailure?
          /// Sessão, não persiste, e é independente do transcript. O nome não é
          /// `briefing` porque o método com esse nome já ocupa o identificador.
          public private(set) var briefingText: String?

          public let scope: AssistantScope
          public let context: AssistantContext
          public let destination: AssistantDestination

          private let engine: AssistantEngine
          @ObservationIgnored private var currentTask: Task<Void, Never>?
          @ObservationIgnored private var lastAction: Action?

          enum Action: Equatable {
              case ask(String)
              case draftReply
              case briefing
          }

          public init(
              scope: AssistantScope,
              context: AssistantContext,
              destination: AssistantDestination,
              engine: AssistantEngine,
              debugState: AssistantPanelDebugState = .empty
          ) {
              self.scope = scope
              self.context = context
              self.destination = destination
              self.engine = engine
              self.messages = debugState.messages
              self.draft = debugState.draft
              self.isLoading = debugState.isLoading
              self.failure = debugState.failure
              self.briefingText = debugState.briefingText
          }

          public var canSend: Bool {
              !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isLoading
          }

          /// Rascunho só existe com email ou conversa em contexto. Com o
          /// ambiente inteiro o botão não aparece — em vez de aparecer mudo.
          public var canDraftReply: Bool {
              engine.supportsDraftReply && scope == .email
          }

          public var canRetry: Bool { lastAction != nil && !isLoading }
          public var hasConversation: Bool { !messages.isEmpty }

          public func submit() {
              let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
              guard !question.isEmpty else { return }
              draft = ""
              ask(question)
          }

          public func run(_ suggestion: AssistantSuggestion) {
              ask(suggestion.question)
          }

          public func ask(_ question: String) {
              let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
              guard !question.isEmpty else { return }
              start(.ask(question))
          }

          public func summarize() { ask(Self.summaryQuestion) }

          public func draftReply() {
              guard canDraftReply else { return }
              start(.draftReply)
          }

          public func briefing() { start(.briefing) }

          /// Fechar a superfície chama isto. Cancelamento não é falha: quem
          /// fechou a janela não precisa ver "não foi possível responder".
          public func cancel() {
              currentTask?.cancel()
              currentTask = nil
              isLoading = false
          }

          public func clear() {
              cancel()
              messages.removeAll()
              draft = ""
              failure = nil
              briefingText = nil
              lastAction = nil
          }

          public func retry() {
              guard let lastAction, !isLoading else { return }
              start(lastAction, appendingUserTurn: false)
          }

          private func start(_ action: Action, appendingUserTurn: Bool = true) {
              guard !isLoading else { return }
              lastAction = action
              failure = nil

              if case let .ask(question) = action, appendingUserTurn {
                  messages.append(.init(speaker: .user, text: question))
              }

              isLoading = true
              currentTask = Task { [weak self] in
                  guard let self else { return }
                  await self.perform(action)
                  self.isLoading = false
                  self.currentTask = nil
              }
          }

          private func perform(_ action: Action) async {
              let request = AssistantRequest(
                  context: context,
                  question: question(for: action),
                  conversation: Array(messages.suffix(Self.maximumHistoryTurns + 1))
              )
              do {
                  let text: String
                  switch action {
                  case .ask, .briefing:
                      text = try await engine.answer(request)
                  case .draftReply:
                      text = try await engine.draftReply(request)
                  }
                  let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                  guard !trimmed.isEmpty else {
                      failure = AssistantFailure(TextAssistantError.emptyResponse)
                      return
                  }
                  switch action {
                  case .ask:
                      messages.append(.init(speaker: .assistant, text: trimmed))
                  case .draftReply:
                      messages.append(.init(speaker: .assistant, text: trimmed, kind: .draft))
                  case .briefing:
                      briefingText = trimmed
                  }
              } catch is CancellationError {
                  // Fechar a superfície não marca a conversa como falha.
              } catch {
                  failure = AssistantFailure(error)
              }
          }

          private func question(for action: Action) -> String {
              switch action {
              case let .ask(question): question
              case .briefing: Self.briefingQuestion
              // O rascunho parte do texto que já existe no composer; a ponte
              // resolve o rascunho atual e o entrega aqui. Vazio é legítimo.
              case .draftReply: ""
              }
          }
      }

      #if DEBUG
      public extension AssistantConversation {
          /// Espera o pedido em voo terminar. Existe para o teste não precisar
          /// de `Task.sleep`, que é o que transforma suíte em loteria.
          func waitForIdle() async { await currentTask?.value }
      }
      #endif
      ```
      `currentTask` precisa ser visível na extensão `#if DEBUG` do mesmo arquivo: deixe-o `private` e a extensão no **mesmo** arquivo (extensão no mesmo arquivo enxerga `private`).

- [ ] Construir o motor na ponte. Acrescentar a `Packages/UNIShell/Sources/UNIShell/Support/AssistantBridge.swift`:
      ```swift
      public extension AssistantBridge {
          /// O contexto é resolvido **no momento da chamada**: a mensagem aberta
          /// pode ter mudado desde que a superfície abriu, e o corpo pode ter
          /// acabado de chegar da rede.
          @MainActor
          static func engine(
              using assistant: any TextAssisting,
              supportsDraftReply: Bool,
              mailContext: @escaping @MainActor () async throws -> AssistantMailContext,
              currentDraft: @escaping @MainActor () -> String = { "" }
          ) -> AssistantEngine {
              AssistantEngine(
                  supportsDraftReply: supportsDraftReply,
                  answer: { request in
                      try await AssistantBridge.answer(
                          request,
                          mailContext: try await mailContext(),
                          using: assistant
                      )
                  },
                  draftReply: { _ in
                      let context = try await mailContext()
                      if case .workspace = context {
                          throw TextAssistantError.invalidRequest(
                              "Criar uma resposta requer contexto de e-mail."
                          )
                      }
                      return try await assistant.transform(
                          currentDraft(),
                          using: .draftReply,
                          context: context
                      )
                  }
              )
          }
      }
      ```
      `AssistantBridge.answer` (linhas 21–46 do arquivo) já corta o turno do usuário duplicado; deixe-o como está, apenas troque o teto do histórico para `AssistantConversation.maximumHistoryTurns` na hora de montar `turns`:
      ```swift
      let turns = history.suffix(AssistantConversation.maximumHistoryTurns).map { message in
          AssistantTurn(
              role: message.speaker == .user ? .user : .assistant,
              text: message.text
          )
      }
      ```

- [ ] Fazer o painel receber a conversa em vez de criá-la. Em `AssistantPanel.swift`, trocar `@State private var conversation` (linha 288) e o `init` (linhas 299–322) por:
      ```swift
      private let conversation: AssistantConversation
      private let onClose: () -> Void
      private let onOpenSettings: () -> Void
      private let width: CGFloat

      public init(
          conversation: AssistantConversation,
          suggestions: [AssistantSuggestion]? = nil,
          width: CGFloat = AssistantPanel.defaultWidth,
          onOpenSettings: @escaping () -> Void = {},
          onClose: @escaping () -> Void
      ) {
          self.conversation = conversation
          self.suggestions = suggestions ?? conversation.scope.suggestions
          self.width = width
          self.onOpenSettings = onOpenSettings
          self.onClose = onClose
      }
      ```
      O cabeçalho passa a mostrar `conversation.destination.label.uppercased()` no lugar de `providerLabel`; o rodapé (`mode.footer`, linha 620) passa a mostrar `conversation.destination.detail`; a faixa de erro (linhas 532–565) é substituída por
      ```swift
      if let failure = conversation.failure {
          AssistantFailureBand(
              failure: failure,
              onRetry: conversation.retry,
              onOpenSettings: onOpenSettings
          )
      }
      ```
      e `submit()` (linha 629) vira `conversation.submit()`; `suggestionButton` chama `conversation.run(suggestion)` sem `Task`; o botão de limpar chama `conversation.clear`.

- [ ] Fechar a superfície cancela. Em `AssistantPanel.body`, acrescentar depois de `.accessibilityIdentifier("local-assistant-panel")`:
      ```swift
      .onDisappear { conversation.cancel() }
      ```
      e mudar o identificador para `"assistant-panel"` (a cópia "local" também some daqui). Atualize `AssistantPanelTests` e `InboxAssistantIntegrationTests` que procuram o identificador antigo:
      ```bash
      git grep -n 'local-assistant-panel' -- '*.swift'
      ```

- [ ] Rodar e ver passar:
      ```bash
      swift test --package-path Packages/UNIShell --filter AssistantConversationTests
      swift test --package-path Packages/UNIShell
      ```
      Esperado: `✔ Test run with 8 tests in 1 suite passed` e depois a suíte inteira verde. `InboxScreen`, `MessageWindow`, `ReaderPane` e `DashboardScreen` ainda passam pelo caminho antigo — se a compilação quebrar neles, a Task 9 é quem os move; nesta tarefa faça o mínimo para compilar (construir a `AssistantConversation` no ponto onde hoje se constrói o painel).

- [ ] Provar por mutação: troque `kind: .draft` por `kind: .message` no ramo `.draftReply` e confirme que `draftReplyUsesTransform` falha; desfaça. Troque `engine.draftReply(request)` por `engine.answer(request)` e confirme que o mesmo teste falha por `spy.answers` não estar vazio; desfaça. Troque `maximumHistoryTurns` para 20 e confirme que `historyIsCappedAtSixteen` falha; desfaça.

- [ ] Commit:
      ```bash
      git add -A && git commit -m "feat: AssistantConversation é a única máquina de estado

Transcript, isLoading, failure e Task numa dona só; draftReply passa por
transform(.draftReply) e vira turno .draft; histórico 16 em toda
superfície; cancel() de verdade. Spec 1.3.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
      ```

---

### Task 9: Dashboard, janela de mensagem e popover consomem a conversa (spec 1.3)

`DashboardScreen.run/runDraft/runSuggestion` somem. "Gerar rascunho" passa a chamar `draftReply()`.

**Files**
- Modify `Packages/UNIShell/Sources/UNIShell/Inbox/DashboardScreen.swift` (`init` em `:37-64`; `transcriptList` em `:429-447`; `draftButton` em `:448-465`; `askScope`/`run` em `:695-778`)
- Modify `Packages/UNIShell/Sources/UNIShell/Inbox/InboxScreen.swift` (`assistantPanel` em `:660-676`; `askAssistant` em `:686-712`)
- Modify `Packages/UNIShell/Sources/UNIShell/Windows/MessageWindow.swift` (`:18-37`, `:70-82`)
- Modify `Packages/UNIShell/Sources/UNIShell/Inbox/ReaderIntelligencePopover.swift` (recebe `AssistantConversation`)
- Modify `Packages/UNIShell/Tests/UNIShellTests/DashboardScreenTests.swift`

**Interfaces**
- Consumes: `AssistantConversation`, `AssistantEngine`, `AssistantBridge.engine(using:supportsDraftReply:mailContext:currentDraft:)` (Task 8); `AssistantDestination` (Task 3).
- Produces:
  ```swift
  struct DashboardScreen: View {
      init(
          store: MailStore,
          now: Int,
          today: Date,
          conversation: AssistantConversation,
          selectedMailID: Binding<String?> = .constant(nil),
          readingMailID: Binding<String?> = .constant(nil),
          onPresented: @escaping (String) -> Void = { _ in },
          onOpenMessage: @escaping (Message) -> Void = { _ in },
          onOpenEvent: @escaping (AgendaItem) -> Void = { _ in },
          onShowMail: @escaping () -> Void = {},
          onShowCalendar: @escaping () -> Void = {},
          onOpenSettings: @escaping () -> Void = {}
      )
  }
  ```
  `transcript`, `draft` e `onAsk` saem do `init`: o transcript agora é `conversation.messages`, o campo é `conversation.draft` e a rota é `conversation.ask/draftReply`.

**Steps**

- [ ] Escrever o teste que falha. Acrescentar a `Packages/UNIShell/Tests/UNIShellTests/DashboardScreenTests.swift`:
      ```swift
      @Test("\"Gerar rascunho\" chama draftReply(), não ask()")
      func draftButtonUsesDraftReply() async throws {
          let store = MailStore(source: InMemoryMailSource.fixtures)
          await store.load()
          let spy = SpyTextAssistant()
          let mail = try #require(store.dashboardFocus(nowMinute: Fixtures.nowMinute).mail.first)
          let conversation = AssistantConversation(
              scope: .email,
              context: .init(subject: mail.message.subject, sender: mail.message.from.display),
              destination: .init(label: "Neste Mac", detail: "Nada sai deste Mac.", isLocal: true),
              engine: AssistantBridge.engine(
                  using: spy,
                  supportsDraftReply: true,
                  mailContext: { AssistantMailContext(message: mail.message) }
              )
          )
          conversation.draftReply()
          await conversation.waitForIdle()

          #expect(spy.transforms.map(\.action) == [.draftReply])
          #expect(spy.answers.isEmpty)
          #expect(conversation.messages.last?.kind == .draft)
      }

      @Test("o dashboard não tem mais máquina de estado própria")
      func dashboardHasNoOwnStateMachine() throws {
          let source = try String(
              contentsOf: URL(fileURLWithPath: #filePath)
                  .deletingLastPathComponent()
                  .deletingLastPathComponent()
                  .deletingLastPathComponent()
                  .appendingPathComponent("Sources/UNIShell/Inbox/DashboardScreen.swift"),
              encoding: .utf8
          )
          #expect(!source.contains("private func run("))
          #expect(!source.contains("private func runDraft("))
          #expect(!source.contains("private func runSuggestion("))
          #expect(!source.contains("@State private var loading"))
          #expect(!source.contains("@State private var errorMessage"))
      }
      ```
      O segundo teste lê o próprio arquivo-fonte: é grosseiro de propósito. A spec manda **remover** os três métodos, e nenhuma asserção de comportamento prova remoção — só a ausência do texto prova.

- [ ] Rodar e ver falhar:
      ```bash
      swift test --package-path Packages/UNIShell --filter DashboardScreenTests
      ```
      Esperado: `extra argument 'conversation' in call` e, em `dashboardHasNoOwnStateMachine`, quatro `#expect` falhando com `Expectation failed: !source.contains("private func run(")`.

- [ ] Trocar o `init` e o corpo do dashboard. Em `DashboardScreen.swift`:
      - apagar `@Binding var transcript`, `@Binding var draft`, `let onAsk`, `@State private var loading`, `@State private var errorMessage`, `static let briefingQuestion` (ela agora é `AssistantConversation.briefingQuestion`) e os três métodos `run`, `runDraft`, `runSuggestion` (linhas 728–778);
      - acrescentar `let conversation: AssistantConversation` e `let onOpenSettings: () -> Void`;
      - `transcriptList` (linha 429) passa a iterar `conversation.messages` e a renderizar:
        ```swift
        ForEach(conversation.messages) { message in
            VStack(alignment: .leading, spacing: 4) {
                Text(message.speaker == .user ? "Você" : "Assistente")
                    .font(theme.sans.font(size: 11, weight: .medium))
                    .foregroundStyle(theme.ink4.color)
                if message.speaker == .user || message.kind == .draft {
                    Text(message.text)
                        .font(theme.sans.font(size: 13.5))
                        .foregroundStyle(theme.ink.color)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    AssistantMarkdown(text: message.text)
                }
            }
        }
        ```
      - `draftButton` (linha 448) vira:
        ```swift
        private func draftButton(_ focus: DashboardFocus) -> some View {
            Button {
                if conversation.canDraftReply {
                    conversation.draftReply()
                } else {
                    conversation.briefing()
                }
            } label: {
                Text(conversation.canDraftReply ? "Gerar rascunho" : "Gerar briefing")
                    .font(theme.sans.font(size: 11.5, weight: .semibold))
                    .foregroundStyle(theme.onAccent.color)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(theme.accent.color, in: Capsule())
            }
            .buttonStyle(.plain)
            .focusRing(cornerRadius: 14, tint: \.onAccent)
            .disabled(conversation.isLoading)
            .help(conversation.canDraftReply
                ? "Pede um rascunho do email em foco"
                : "Pede um briefing do dia")
            .accessibilityLabel(conversation.canDraftReply ? "Gerar rascunho" : "Gerar briefing")
        }
        ```
      - a faixa de erro passa a ser
        ```swift
        if let failure = conversation.failure {
            AssistantFailureBand(
                failure: failure,
                onRetry: conversation.retry,
                onOpenSettings: onOpenSettings
            )
        }
        ```
      - o briefing gerado aparece acima do campo, em superfície plana e hairline (nada de cartão flutuante — a faixa desenhada da §2.2 é do sub-projeto 2):
        ```swift
        @ViewBuilder
        private var briefingBand: some View {
            if let text = conversation.briefingText {
                VStack(alignment: .leading, spacing: 6) {
                    Text("BRIEFING")
                        .capsLabel(size: 8.5)
                    AssistantMarkdown(text: text)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(theme.surface2.color)
                .hairline(theme.line2, edges: [.top, .bottom])
            }
        }
        ```
      - o campo mostra o destino embaixo:
        ```swift
        Text(conversation.destination.label)
            .font(theme.sans.font(size: 11))
            .foregroundStyle(theme.ink3.color)
        ```
      - `DashboardMailSheet`'s `onDraft` (linha 92) passa a `{ message in readingMailID = nil; selectedMailID = message.id; conversation.draftReply() }`.

- [ ] Dono da conversa no `InboxScreen`. Em `InboxScreen.swift`, trocar `@State private var assistantTranscript`/`assistantDraft` (procure com `git grep -n 'assistantTranscript\|assistantDraft' -- Packages/UNIShell`) por:
      ```swift
      @State private var assistantConversation: AssistantConversation?

      private func makeConversation(for scope: InboxAssistantScope) -> AssistantConversation? {
          guard let textAssistant else { return nil }
          let destination = AssistantDestination(
              settings: assistantSettings?.snapshot() ?? .default
          )
          return AssistantConversation(
              scope: scope.mode,
              context: assistantContext(for: scope),
              destination: destination,
              engine: AssistantBridge.engine(
                  using: textAssistant,
                  supportsDraftReply: scope.mode == .email,
                  mailContext: { try await self.mailContext(for: scope) },
                  currentDraft: {
                      guard case let .email(id) = scope else { return "" }
                      return store.replyDraft(for: id)?.text ?? ""
                  }
              )
          )
      }

      /// O que `askAssistant` fazia antes das linhas 686–712, agora só a
      /// resolução do contexto — a máquina de estado é da conversa.
      private func mailContext(for scope: InboxAssistantScope) async throws -> AssistantMailContext {
          switch scope {
          case .workspace:
              return AssistantMailContext(workspace: store)
          case let .email(messageID):
              let ids = store.conversation(of: messageID)?.messageIDs ?? [messageID]
              for id in ids { await store.loadBodyIfNeeded(id) }
              guard let loaded = store.assistantMailContext(for: messageID) else {
                  throw TextAssistantError.invalidRequest("O email selecionado não está mais disponível.")
              }
              return loaded
          }
      }
      ```
      `openWorkspaceAssistant()`/`openEmailAssistant()` passam a fazer `assistantConversation = makeConversation(for: scope)`; `closeAssistant()` chama `assistantConversation?.cancel()`. `assistantPanel` passa `conversation:` e `onOpenSettings: openAccounts`.

- [ ] `MessageWindow` recebe a conversa. Em `MessageWindow.swift`, trocar `textAssistant`/`assistantSettings`/`assistantProviderLabel` (linhas 18–19, 49) por `let conversation: AssistantConversation?` e passar `conversation` ao `AssistantPanel` (linha 70). Quem constrói é `App/OkamiUNIApp.swift`, na cena `UNIWindow.message`.

- [ ] `ReaderIntelligencePopover` recebe a conversa. Trocar o `onAsk`/estado interno pelo mesmo padrão: `let conversation: AssistantConversation`, `onGenerateReply` passa a ser `conversation.draftReply()` e "Usar no composer" lê `conversation.messages.last(where: { $0.kind == .draft })?.text`. `ReaderPane.generateReply(for:)` (`:870-892`) é apagado: ele existia só para o popover, e agora o caminho é o mesmo `transform(.draftReply)` da conversa.

- [ ] Rodar e ver passar:
      ```bash
      swift test --package-path Packages/UNIShell
      xcodegen generate && xcodebuild -project OkamiUNI.xcodeproj -scheme OkamiUNI -configuration Debug build 2>&1 | grep -E "error:|BUILD"
      ```
      Esperado: suíte verde e `** BUILD SUCCEEDED **`.

- [ ] Commit:
      ```bash
      git add -A && git commit -m "refactor: dashboard, janela e popover usam a mesma conversa

Três caminhos de gerar rascunho viraram um: transform(.draftReply). O
dashboard perde run/runDraft/runSuggestion e o estado duplicado.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
      ```

---

### Task 10: `AssistantAvailability`, `didChange` e a apresentação honesta (spec 1.5)

`AssistantRouter.availability()` não tem chamador fora dos testes; `IntelligencePresentation` é `.configuredAssistant` cravado em `App/OkamiUNIApp.swift:136` e `:259`. Não existe estado "não configurado".

**Files**
- Create `Packages/UNISync/Sources/UNISync/AssistantAvailability.swift`
- Modify `Packages/UNISync/Sources/UNISync/AssistantRouter.swift` (`availability()` em `:59-102`)
- Modify `Packages/UNISync/Sources/UNISync/AssistantSettingsStore.swift`
- Modify `Packages/UNISync/Sources/UNISync/AppComposition.swift`
- Modify `Packages/UNIShell/Sources/UNIShell/Inbox/FolderSidebar.swift` (`IntelligencePresentation` em `:11-84`)
- Modify `App/OkamiUNIApp.swift` (`:136`, `:259`)
- Create `Packages/UNISync/Tests/UNISyncTests/AssistantAvailabilityTests.swift`
- Modify `Packages/UNIShell/Tests/UNIShellTests/IntelligenceFooterTests.swift`

> **Desvio consciente da spec:** a spec diz que `AssistantRouter.availability()` "vira" `AssistantAvailability`. Não pode: `availability()` é requisito de `TextAssisting` e devolve `AppleIntelligenceAvailability`; `AssistantAvailability` mora em UNISync e carrega `AssistantDestination`, que UNICore não enxerga. O método rico chama-se `assistantAvailability()`; o do protocolo passa a ser derivado dele, e é assim que a fila de análise e o `MessageIntelligenceCoordinator` continuam funcionando.

**Interfaces**
- Produces:
  ```swift
  public enum AssistantAvailability: Sendable, Hashable {
      case ready(AssistantDestination)
      case needsSetup(AssistantDestination, reason: String)
      case needsSignIn(AssistantDestination, provider: AssistantProviderOAuthKind?)
      case appleIntelligence(AppleIntelligenceAvailability)

      public var destination: AssistantDestination
      public var isReady: Bool
      public var reason: String?
  }

  @available(macOS 26.0, *)
  public extension AssistantRouter {
      nonisolated func destination() -> AssistantDestination
      func assistantAvailability() async -> AssistantAvailability
  }

  @MainActor @Observable
  public final class AssistantAvailabilityModel {
      public private(set) var availability: AssistantAvailability
      public init(settingsStore: AssistantSettingsStore, probe: @escaping @Sendable () async -> AssistantAvailability)
      public func refresh() async
  }

  public extension AssistantSettingsStore {
      func addDidChangeHandler(_ handler: @escaping @Sendable (AssistantSettings) -> Void)
  }
  ```

**Steps**

- [ ] Escrever o teste que falha. `Packages/UNISync/Tests/UNISyncTests/AssistantAvailabilityTests.swift`:
      ```swift
      import Foundation
      import Testing
      @testable import UNISync
      import UNICore

      @Suite("Disponibilidade do assistente")
      struct AssistantAvailabilityTests {
          private func store(_ settings: AssistantSettings) throws -> AssistantSettingsStore {
              let suite = "okamiuni.assistant-availability.\(UUID().uuidString)"
              let defaults = try #require(UserDefaults(suiteName: suite))
              defaults.removePersistentDomain(forName: suite)
              let store = AssistantSettingsStore(defaults: defaults, key: "assistant")
              try store.save(settings)
              return store
          }

          @Test("endpoint sem chave pede configuração, com o motivo")
          @available(macOS 26.0, *)
          func apiKeyMissingNeedsSetup() async throws {
              let settings = AssistantSettings(
                  provider: .openAICompatible,
                  openAICompatible: .init(
                      endpoint: "https://api.example.com/v1", model: "m",
                      credentialID: "primary", authenticationMode: .apiKey
                  )
              )
              let credentials = InMemoryAssistantCredentialStore()
              let router = AssistantRouter(settingsStore: try store(settings), credentialStore: credentials)

              let availability = await router.assistantAvailability()
              #expect(availability == .needsSetup(
                  .init(settings: settings),
                  reason: "Adicione a chave de API deste provedor."
              ))
              #expect(!availability.isReady)
              #expect(availability.destination.label == "API · api.example.com")
          }

          @Test("com chave presente o destino fica pronto")
          @available(macOS 26.0, *)
          func apiKeyPresentIsReady() async throws {
              let settings = AssistantSettings(
                  provider: .openAICompatible,
                  openAICompatible: .init(
                      endpoint: "https://api.example.com/v1", model: "m",
                      credentialID: "primary", authenticationMode: .apiKey
                  )
              )
              let credentials = InMemoryAssistantCredentialStore()
              try credentials.storeAPIKey("k", for: "primary")
              let router = AssistantRouter(settingsStore: try store(settings), credentialStore: credentials)
              #expect(await router.assistantAvailability() == .ready(.init(settings: settings)))
          }

          @Test("assinatura sem sessão pede login, nomeando o provedor")
          @available(macOS 26.0, *)
          func providerOAuthWithoutSession() async throws {
              let settings = AssistantSettings(
                  provider: .providerOAuth,
                  providerOAuth: .init(kind: .xAI, model: "grok-4.6")
              )
              let router = AssistantRouter(
                  settingsStore: try store(settings),
                  credentialStore: InMemoryAssistantCredentialStore(),
                  providerOAuthTokenProvider: nil
              )
              #expect(await router.assistantAvailability()
                  == .needsSignIn(.init(settings: settings), provider: .xAI))
          }

          @Test("CLI não encontrado pede configuração e nomeia o binário")
          @available(macOS 26.0, *)
          func cliNotFoundNeedsSetup() async throws {
              let settings = AssistantSettings(provider: .cli, cli: .init(kind: .claude))
              let router = AssistantRouter(
                  settingsStore: try store(settings),
                  credentialStore: InMemoryAssistantCredentialStore(),
                  cliInstallationProvider: { [.init(kind: .claude, executablePath: nil)] }
              )
              #expect(await router.assistantAvailability() == .needsSetup(
                  .init(settings: settings),
                  reason: "O Claude Code não foi encontrado neste Mac."
              ))
          }

          @Test("o Foundation Models reporta o estado da Apple Intelligence, não um destino pronto")
          @available(macOS 26.0, *)
          func foundationModelsReportsAppleIntelligence() async throws {
              let router = AssistantRouter(
                  settingsStore: try store(.init(provider: .foundationModels)),
                  credentialStore: InMemoryAssistantCredentialStore()
              )
              let availability = await router.assistantAvailability()
              switch availability {
              case .ready(let destination):
                  #expect(destination.isLocal)
              case .appleIntelligence(let state):
                  #expect(state != .available)
              default:
                  Issue.record("Foundation Models não pode cair em needsSetup/needsSignIn: \(availability)")
              }
          }

          @Test("salvar preferências avisa quem observa")
          func storePublishesChanges() throws {
              let suite = "okamiuni.assistant-didchange.\(UUID().uuidString)"
              let defaults = try #require(UserDefaults(suiteName: suite))
              defaults.removePersistentDomain(forName: suite)
              let store = AssistantSettingsStore(defaults: defaults, key: "assistant")
              let box = Box()
              store.addDidChangeHandler { settings in box.record(settings.provider) }

              try store.save(.init(provider: .cli, cli: .init(kind: .openCode)))
              try store.reset()
              #expect(box.providers == [.cli, .foundationModels])
          }

          final class Box: @unchecked Sendable {
              private let lock = NSLock()
              private var values: [AssistantProvider] = []
              var providers: [AssistantProvider] { lock.withLock { values } }
              func record(_ provider: AssistantProvider) { lock.withLock { values.append(provider) } }
          }
      }
      ```

- [ ] Rodar e ver falhar:
      ```bash
      swift test --package-path Packages/UNISync --filter AssistantAvailabilityTests
      ```
      Esperado: `cannot find 'AssistantAvailability' in scope` e `value of type 'AssistantSettingsStore' has no member 'addDidChangeHandler'`.

- [ ] Implementar `AssistantAvailability`. `Packages/UNISync/Sources/UNISync/AssistantAvailability.swift`:
      ```swift
      import Foundation
      import Observation
      import UNICore

      /// O que o app pode afirmar sobre o assistente **sem tocar na rede**.
      ///
      /// Lê o snapshot das preferências, a presença de credencial (sem
      /// materializá-la), a presença de sessão OAuth (sem renová-la) e o cache
      /// de CLIs. Um botão desabilitado sem motivo é um controle mudo, e isso é
      /// defeito neste projeto.
      public enum AssistantAvailability: Sendable, Hashable {
          case ready(AssistantDestination)
          case needsSetup(AssistantDestination, reason: String)
          case needsSignIn(AssistantDestination, provider: AssistantProviderOAuthKind?)
          case appleIntelligence(AppleIntelligenceAvailability)

          public var destination: AssistantDestination {
              switch self {
              case let .ready(destination): destination
              case let .needsSetup(destination, _): destination
              case let .needsSignIn(destination, _): destination
              case .appleIntelligence:
                  AssistantDestination(
                      label: "Neste Mac", detail: "Nada sai deste Mac.", isLocal: true
                  )
              }
          }

          public var isReady: Bool {
              switch self {
              case .ready: true
              case let .appleIntelligence(state): state == .available
              case .needsSetup, .needsSignIn: false
              }
          }

          /// O texto que o botão desabilitado mostra. `nil` só quando está pronto.
          public var reason: String? {
              switch self {
              case .ready: nil
              case let .needsSetup(_, reason): reason
              case let .needsSignIn(destination, _): "Entre na assinatura \(destination.label) para usar a IA."
              case let .appleIntelligence(state):
                  switch state {
                  case .available: nil
                  case .deviceNotEligible: "Este Mac não é compatível com a Apple Intelligence."
                  case .appleIntelligenceNotEnabled: "Ative a Apple Intelligence nos Ajustes do Sistema."
                  case .modelNotReady: "A Apple Intelligence ainda está sendo preparada."
                  }
              }
          }
      }

      /// O estado que a interface observa. Recalculado a cada `save` das
      /// preferências, porque trocar de provedor sem a lateral perceber era
      /// exatamente como o app acabava mostrando "local" com Grok escolhido.
      @MainActor
      @Observable
      public final class AssistantAvailabilityModel {
          public private(set) var availability: AssistantAvailability

          private let probe: @Sendable () async -> AssistantAvailability

          public init(
              settingsStore: AssistantSettingsStore,
              probe: @escaping @Sendable () async -> AssistantAvailability
          ) {
              self.probe = probe
              self.availability = .ready(AssistantDestination(settings: settingsStore.snapshot()))
              settingsStore.addDidChangeHandler { [weak self] _ in
                  Task { @MainActor in await self?.refresh() }
              }
          }

          public func refresh() async {
              availability = await probe()
          }
      }
      ```

- [ ] Publicar mudanças no cofre de preferências. Em `AssistantSettingsStore.swift`, acrescentar ao corpo da classe:
      ```swift
      private var didChangeHandlers: [@Sendable (AssistantSettings) -> Void] = []

      /// Quem observa é avisado **fora** do lock: um handler que voltasse a
      /// chamar `snapshot()` travaria o cofre contra si mesmo.
      public func addDidChangeHandler(_ handler: @escaping @Sendable (AssistantSettings) -> Void) {
          lock.lock()
          didChangeHandlers.append(handler)
          lock.unlock()
      }

      private func publishDidChange(_ settings: AssistantSettings) {
          lock.lock()
          let handlers = didChangeHandlers
          lock.unlock()
          for handler in handlers { handler(settings) }
      }
      ```
      e, no fim de `save(_:)` (linha 49), depois de `cached = normalized` e **fora** do escopo do lock:
      ```swift
      @discardableResult
      public func save(_ settings: AssistantSettings) throws -> AssistantSettings {
          let normalized = try settings.migrated()
          lock.lock()
          do {
              try Self.persist(normalized, defaults: defaults, key: key)
          } catch {
              lock.unlock()
              throw error
          }
          cached = normalized
          lock.unlock()
          publishDidChange(normalized)
          return normalized
      }
      ```

- [ ] Implementar o cálculo no roteador. Em `AssistantRouter.swift`, substituir `availability()` (linhas 59–102) por:
      ```swift
      public nonisolated func destination() -> AssistantDestination {
          AssistantDestination(settings: settingsStore.snapshot())
      }

      /// Barata de propósito: nenhuma chamada de rede, nenhuma leitura de
      /// segredo, nenhuma renovação de token. É consultada a cada abertura de
      /// tela e a cada `save` das preferências.
      public func assistantAvailability() async -> AssistantAvailability {
          let settings = settingsStore.snapshot()
          let destination = AssistantDestination(settings: settings)
          switch settings.provider {
          case .foundationModels:
              let state = FoundationModelsTextAssistant.systemAvailability
              return state == .available ? .ready(destination) : .appleIntelligence(state)
          case .openAICompatible:
              guard let configuration = try? settings.openAICompatible.validated(),
                    let endpoint = try? configuration.chatCompletionsURL()
              else {
                  return .needsSetup(destination, reason: "Confira o endpoint e o modelo deste provedor.")
              }
              switch configuration.authenticationMode {
              case .none:
                  return .ready(destination)
              case .apiKey:
                  guard (try? credentialStore.credentialPresence(for: configuration.credentialID)) == .present else {
                      return .needsSetup(destination, reason: "Adicione a chave de API deste provedor.")
                  }
                  return .ready(destination)
              case .litellmOAuthPKCE:
                  guard let oauthTokenProvider,
                        await oauthTokenProvider.hasAccessToken(
                            for: configuration.credentialID, endpoint: endpoint
                        )
                  else {
                      return .needsSignIn(destination, provider: nil)
                  }
                  return .ready(destination)
              }
          case .providerOAuth:
              guard let configuration = try? settings.providerOAuth.validated() else {
                  return .needsSetup(destination, reason: "Escolha um modelo para esta assinatura.")
              }
              guard let providerOAuthTokenProvider,
                    await providerOAuthTokenProvider.hasAccessToken(for: configuration)
              else {
                  return .needsSignIn(destination, provider: configuration.kind)
              }
              if configuration.kind == .codex,
                 cliInstallationProvider().first(where: { $0.kind == .codex && $0.isDetected }) == nil {
                  return .needsSetup(destination, reason: "O runtime do Codex não foi encontrado neste Mac.")
              }
              return .ready(destination)
          case .cli:
              guard let installation = cliInstallationProvider().first(where: {
                  $0.kind == settings.cli.kind && $0.isDetected
              }), (try? AssistantCLICommand.make(kind: settings.cli.kind, installation: installation)) != nil
              else {
                  return .needsSetup(
                      destination,
                      reason: "O \(settings.cli.kind.displayName) não foi encontrado neste Mac."
                  )
              }
              return .ready(destination)
          }
      }

      /// O requisito do protocolo continua existindo — é ele que a fila de
      /// análise consulta. Agora é derivado, e não uma segunda regra.
      public func availability() async -> AppleIntelligenceAvailability {
          switch await assistantAvailability() {
          case .ready: .available
          case let .appleIntelligence(state): state
          case .needsSetup, .needsSignIn: .modelNotReady
          }
      }
      ```

- [ ] Refazer `IntelligencePresentation`. Em `FolderSidebar.swift`, substituir o enum (linhas 11–84) por:
      ```swift
      /// O que a lateral pode afirmar sobre o assistente neste momento.
      /// Deixou de ser `CaseIterable`: os casos carregam o destino, e é ele que
      /// impede a barra de prometer processamento local com Grok escolhido.
      public enum IntelligencePresentation: Sendable, Hashable {
          case available(AssistantDestination)
          case needsSetup(AssistantDestination, detail: String)
          case needsSignIn(AssistantDestination, provider: AssistantProviderOAuthKind?)
          case deviceNotEligible
          case appleIntelligenceNotEnabled
          case modelNotReady

          public init(_ availability: AssistantAvailability) {
              switch availability {
              case let .ready(destination):
                  self = .available(destination)
              case let .needsSetup(destination, reason):
                  self = .needsSetup(destination, detail: reason)
              case let .needsSignIn(destination, provider):
                  self = .needsSignIn(destination, provider: provider)
              case let .appleIntelligence(state):
                  switch state {
                  case .available:
                      self = .available(.init(label: "Neste Mac", detail: "Nada sai deste Mac.", isLocal: true))
                  case .deviceNotEligible: self = .deviceNotEligible
                  case .appleIntelligenceNotEnabled: self = .appleIntelligenceNotEnabled
                  case .modelNotReady: self = .modelNotReady
                  }
              }
          }

          public var actionTitle: String { "Perguntar ao ambiente" }

          public var isAvailable: Bool {
              if case .available = self { return true }
              return false
          }

          public var destination: AssistantDestination? {
              switch self {
              case let .available(destination): destination
              case let .needsSetup(destination, _): destination
              case let .needsSignIn(destination, _): destination
              default: nil
              }
          }

          public var title: String {
              switch self {
              case let .available(destination): destination.label
              case .needsSetup: "Configure a IA"
              case .needsSignIn: "Entre na assinatura"
              case .deviceNotEligible: "Apple Intelligence indisponível"
              case .appleIntelligenceNotEnabled: "Ative a Apple Intelligence"
              case .modelNotReady: "Modelo ainda não está pronto"
              }
          }

          /// A frase que decide se o app pode prometer privacidade. Ela vem do
          /// destino, nunca de um texto fixo.
          public var detail: String {
              switch self {
              case let .available(destination):
                  "Pergunte sobre suas caixas, emails e agenda. \(destination.detail)"
              case let .needsSetup(_, detail): detail
              case let .needsSignIn(destination, _):
                  "Entre na assinatura \(destination.label) para usar a IA."
              case .deviceNotEligible:
                  "Este Mac não é compatível com Apple Intelligence. Seus emails continuam locais."
              case .appleIntelligenceNotEnabled:
                  "Ative-a nos Ajustes do Sistema para gerar resumos e identificar compromissos."
              case .modelNotReady:
                  "A Apple Intelligence ainda está sendo preparada."
              }
          }

          public var symbol: String {
              guard let destination else { return "apple.intelligence" }
              return destination.isLocal ? "apple.intelligence" : "sparkles"
          }

          public var scopeLabel: String {
              guard let destination else { return "Todo o OkamiUNI" }
              return "Todo o OkamiUNI · \(destination.label)"
          }

          public var actionHelp: String { isAvailable ? "Abre o assistente global para suas caixas, emails e agenda." : detail }
      }
      ```
      `usesConfiguredProvider` some (só existia para escolher o glifo). `IntelligenceFooter` (a partir da linha 86) ganha, quando `!isAvailable`, um segundo botão:
      ```swift
      if !presentation.isAvailable {
          ChromeButton("Abrir Ajustes", appearance: .outlined,
                       size: 11, height: 24, horizontalPadding: 9,
                       action: onOpenSettings)
              .help(presentation.detail)
      }
      ```
      com `let onOpenSettings: () -> Void` novo na struct; `SidebarRail` passa a mesma closure.

- [ ] Ligar na composição. Em `AppComposition.swift`, acrescentar a propriedade e montá-la em `make` (linhas 148–158):
      ```swift
      /// Recalculado a cada save das preferências; a interface só observa.
      public let assistantAvailability: AssistantAvailabilityModel
      ```
      ```swift
      let router = AssistantRouter(
          settingsStore: assistantSettings,
          credentialStore: assistantCredentials,
          oauthTokenProvider: liteLLMOAuth,
          providerOAuthTokenProvider: assistantProviderOAuth,
          cliInstallationProvider: { cliDiscovery.installations() }   // Task 11
      )
      let textAssistant: any TextAssisting = router
      let assistantAvailability = AssistantAvailabilityModel(
          settingsStore: assistantSettings,
          probe: { await router.assistantAvailability() }
      )
      ```
      e passar `assistantAvailability:` nos dois `return AppComposition(...)` da função.

- [ ] Trocar a fiação do app. Em `App/OkamiUNIApp.swift`, linhas 136 e 259, `intelligencePresentation: .configuredAssistant` vira:
      ```swift
      intelligencePresentation: IntelligencePresentation(composition.assistantAvailability.availability),
      ```
      e a cena principal ganha, no `.task`, o primeiro cálculo:
      ```swift
      .task { await composition.assistantAvailability.refresh() }
      ```

- [ ] Atualizar `IntelligenceFooterTests`: `allCases` não existe mais; a tabela da linha 18 passa a listar os casos à mão, e as asserções das linhas 66–78 sobre `.configuredAssistant`/`.available` viram:
      ```swift
      let remote = IntelligencePresentation.available(
          .init(label: "Grok · xAI", detail: "Sai deste Mac para a xAI.", isLocal: false)
      )
      #expect(remote.scopeLabel == "Todo o OkamiUNI · Grok · xAI")
      #expect(remote.detail.contains("Sai deste Mac para a xAI."))
      #expect(remote.symbol == "sparkles")

      let local = IntelligencePresentation.available(
          .init(label: "Neste Mac", detail: "Nada sai deste Mac.", isLocal: true)
      )
      #expect(local.symbol == "apple.intelligence")
      #expect(local.detail.contains("Nada sai deste Mac."))

      let missing = IntelligencePresentation.needsSetup(
          .init(label: "API · sem endpoint", detail: "Informe o endpoint nos Ajustes.", isLocal: false),
          detail: "Adicione a chave de API deste provedor."
      )
      #expect(!missing.isAvailable)
      #expect(missing.detail == "Adicione a chave de API deste provedor.")
      ```

- [ ] Rodar e ver passar:
      ```bash
      swift test --package-path Packages/UNISync
      swift test --package-path Packages/UNIShell
      xcodegen generate && xcodebuild -project OkamiUNI.xcodeproj -scheme OkamiUNI -configuration Debug build 2>&1 | grep -E "error:|BUILD"
      ```

- [ ] Provar por mutação: faça `assistantAvailability()` devolver sempre `.ready(destination)` e confirme que `apiKeyMissingNeedsSetup`, `providerOAuthWithoutSession` e `cliNotFoundNeedsSetup` falham; desfaça.

- [ ] Commit:
      ```bash
      git add -A && git commit -m "feat: disponibilidade honesta do assistente na lateral

availability() deixa de não ter chamador; a apresentação ganha
needsSetup e needsSignIn, perde .configuredAssistant, e o botão
desabilitado explica o motivo com 'Abrir Ajustes'. Spec 1.5.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
      ```

---

### Task 11: Cache de descoberta de CLIs e stderr capturado (spec 1.6)

`AssistantCLIDiscovery().scan()` varre o disco a cada requisição (`AssistantRouter.swift:42`) e o stderr do processo filho vai para `/dev/null` (`AssistantCLITextAssistant.swift:187`) — é justamente lá que "not logged in" aparece.

**Files**
- Create `Packages/UNISync/Sources/UNISync/CachedAssistantCLIDiscovery.swift`
- Modify `Packages/UNISync/Sources/UNISync/AssistantCLITextAssistant.swift` (`AssistantCLITextAssistantError` em `:301-323`; executor em `:118-200`; tratamento do resultado em `:531-549`)
- Modify `Packages/UNISync/Sources/UNISync/AppComposition.swift`
- Modify `Packages/UNIShell/Sources/UNIShell/Windows/SettingsSections.swift` (invalidar ao salvar)
- Create `Packages/UNISync/Tests/UNISyncTests/CachedAssistantCLIDiscoveryTests.swift`
- Modify `Packages/UNISync/Tests/UNISyncTests/AssistantCLITextAssistantTests.swift`

**Interfaces**
- Produces:
  ```swift
  public final class CachedAssistantCLIDiscovery: @unchecked Sendable {
      public static let validity: TimeInterval = 60
      public init(
          discovery: AssistantCLIDiscovery = .init(),
          validity: TimeInterval = CachedAssistantCLIDiscovery.validity,
          now: @escaping @Sendable () -> Date = Date.init
      )
      public func installations() -> [AssistantCLIInstallation]
      public func invalidate()
  }

  public enum AssistantCLITextAssistantError: Error, Sendable, Equatable, LocalizedError {
      case executableNotFound(AssistantCLIKind)
      case executableNotAllowed
      case timedOut
      case outputTooLarge
      case processFailed(exitCode: Int32, stderrTail: String)
      case invalidResponse
  }
  ```
- Consumes: `AssistantCLIProcessResult.standardError` (`AssistantCLITextAssistant.swift:10`) — o campo **já existe** e sempre chegou vazio.

**Steps**

- [ ] Escrever o teste que falha. `Packages/UNISync/Tests/UNISyncTests/CachedAssistantCLIDiscoveryTests.swift`:
      ```swift
      import Foundation
      import Testing
      @testable import UNISync

      @Suite("Cache da descoberta de CLIs")
      struct CachedAssistantCLIDiscoveryTests {
          @Test("dez chamadas em menos de 60 s varrem o disco uma vez")
          func scansOncePerWindow() {
              let clock = Clock()
              let counter = Counter()
              let cache = CachedAssistantCLIDiscovery(
                  discovery: AssistantCLIDiscovery(
                      environment: ["PATH": "/usr/bin"],
                      homeDirectory: "/tmp/casa",
                      bundleResourceDirectory: nil,
                      isExecutable: { _ in counter.bump(); return false }
                  ),
                  validity: 60,
                  now: { clock.now }
              )
              for _ in 0..<10 { _ = cache.installations() }
              let afterTen = counter.value
              #expect(afterTen > 0)

              clock.advance(59)
              _ = cache.installations()
              #expect(counter.value == afterTen)

              clock.advance(2)
              _ = cache.installations()
              #expect(counter.value > afterTen)
          }

          @Test("salvar Ajustes invalida o cache na hora")
          func invalidateForcesRescan() {
              let clock = Clock()
              let counter = Counter()
              let cache = CachedAssistantCLIDiscovery(
                  discovery: AssistantCLIDiscovery(
                      environment: ["PATH": "/usr/bin"],
                      homeDirectory: "/tmp/casa",
                      bundleResourceDirectory: nil,
                      isExecutable: { _ in counter.bump(); return false }
                  ),
                  validity: 60,
                  now: { clock.now }
              )
              _ = cache.installations()
              let first = counter.value
              _ = cache.installations()
              #expect(counter.value == first)

              cache.invalidate()
              _ = cache.installations()
              #expect(counter.value > first)
          }

          final class Clock: @unchecked Sendable {
              private let lock = NSLock()
              private var seconds: TimeInterval = 0
              var now: Date { lock.withLock { Date(timeIntervalSince1970: seconds) } }
              func advance(_ value: TimeInterval) { lock.withLock { seconds += value } }
          }

          final class Counter: @unchecked Sendable {
              private let lock = NSLock()
              private var count = 0
              var value: Int { lock.withLock { count } }
              func bump() { lock.withLock { count += 1 } }
          }
      }
      ```
      E, em `AssistantCLITextAssistantTests.swift`:
      ```swift
      @Test("o CLI que morreu entrega o stderr, não um silêncio")
      func processFailureCarriesStderr() async {
          let executor = StubAssistantCLIExecutor(result: .init(
              exitStatus: 1,
              standardOutput: Data(),
              standardError: Data("error: not logged in\n".utf8)
          ))
          let assistant = AssistantCLITextAssistant(
              command: try! AssistantCLICommand.make(
                  kind: .codex,
                  installation: .init(kind: .codex, executablePath: "/usr/bin/true")
              ),
              executor: executor
          )
          await #expect(throws: AssistantCLITextAssistantError.processFailed(
              exitCode: 1,
              stderrTail: "error: not logged in"
          )) {
              try await assistant.answer(question: "oi", in: .init(
                  mailContext: .workspace(.init(
                      accounts: [], emailCount: 0, unreadCount: 0,
                      mailboxes: [], emails: [], agenda: []
                  ))
              ))
          }
      }
      ```
      (`StubAssistantCLIExecutor` já existe no conjunto atual; se o nome local for outro, use o que estiver lá.)

- [ ] Rodar e ver falhar:
      ```bash
      swift test --package-path Packages/UNISync --filter 'CachedAssistantCLIDiscoveryTests|AssistantCLITextAssistantTests'
      ```
      Esperado: `cannot find 'CachedAssistantCLIDiscovery' in scope`; e `processFailureCarriesStderr` falhando porque o erro lançado é `.processFailed` sem payload.

- [ ] Implementar o cache. `Packages/UNISync/Sources/UNISync/CachedAssistantCLIDiscovery.swift`:
      ```swift
      import Foundation

      /// A varredura toca dezenas de caminhos do disco. Fazê-la a cada pergunta
      /// é um custo por tecla; guardá-la para sempre faria "instalei o Codex
      /// agora" precisar de reinício. Sessenta segundos, e `invalidate()` ao
      /// salvar Ajustes, resolvem os dois lados.
      public final class CachedAssistantCLIDiscovery: @unchecked Sendable {
          public static let validity: TimeInterval = 60

          private let lock = NSLock()
          private let discovery: AssistantCLIDiscovery
          private let validity: TimeInterval
          private let now: @Sendable () -> Date
          private var cached: [AssistantCLIInstallation]?
          private var scannedAt: Date?

          public init(
              discovery: AssistantCLIDiscovery = .init(),
              validity: TimeInterval = CachedAssistantCLIDiscovery.validity,
              now: @escaping @Sendable () -> Date = Date.init
          ) {
              self.discovery = discovery
              self.validity = validity
              self.now = now
          }

          public func installations() -> [AssistantCLIInstallation] {
              let instant = now()
              lock.lock()
              if let cached, let scannedAt, instant.timeIntervalSince(scannedAt) < validity {
                  lock.unlock()
                  return cached
              }
              lock.unlock()

              // A varredura fica fora do lock: ela toca disco, e prender o
              // cofre durante I/O transformaria uma pergunta lenta em duas.
              let scanned = discovery.scan()
              lock.lock()
              cached = scanned
              scannedAt = instant
              lock.unlock()
              return scanned
          }

          public func invalidate() {
              lock.lock()
              cached = nil
              scannedAt = nil
              lock.unlock()
          }
      }
      ```

- [ ] Capturar o stderr. Em `AssistantCLITextAssistant.swift`:
      - no executor, trocar `process.standardError = FileHandle.nullDevice` (linha 187) por um arquivo temporário irmão do `stdout`, com o mesmo padrão das linhas 161–174:
        ```swift
        let errorURL = workingDirectory.appendingPathComponent("stderr")
        guard fileManager.createFile(
            atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600]
        ) else { throw AssistantCLIProcessError.failedToStart }
        let errorHandle: FileHandle
        do {
            errorHandle = try FileHandle(forWritingTo: errorURL)
        } catch {
            throw AssistantCLIProcessError.failedToStart
        }
        defer { try? errorHandle.close() }
        process.standardError = errorHandle
        ```
        e, onde hoje o resultado é montado com `standardError: Data()`, ler a **cauda** de 4 KiB:
        ```swift
        /// Cauda, e não cabeça: a causa real ("not logged in", "model not
        /// found") vem na última linha, depois de banner e barra de progresso.
        static let maximumStandardErrorBytes = 4 * 1024

        private static func standardErrorTail(at url: URL) -> Data {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
            defer { try? handle.close() }
            guard let size = try? handle.seekToEnd() else { return Data() }
            let offset = size > UInt64(maximumStandardErrorBytes)
                ? size - UInt64(maximumStandardErrorBytes)
                : 0
            try? handle.seek(toOffset: offset)
            return (try? handle.readToEnd()) ?? Data()
        }
        ```
      - o caso do erro (linha 306) vira `case processFailed(exitCode: Int32, stderrTail: String)` e sua descrição:
        ```swift
        case .processFailed:
            "O CLI de IA encerrou com erro."
        ```
      - o tratamento do resultado (linhas 542 e 546–549) passa a carregar o payload:
        ```swift
        case .failedToStart:
            throw AssistantCLITextAssistantError.processFailed(exitCode: -1, stderrTail: "")
        ```
        ```swift
        guard result.exitStatus == 0 else {
            throw AssistantCLITextAssistantError.processFailed(
                exitCode: result.exitStatus,
                stderrTail: String(decoding: result.standardError, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        ```
      Todo `catch { throw AssistantCLITextAssistantError.processFailed }` restante recebe `(exitCode: -1, stderrTail: "")`.

- [ ] Ligar o cache. Em `AppComposition.make`, antes do roteador:
      ```swift
      let cliDiscovery = CachedAssistantCLIDiscovery()
      ```
      e passar `cliInstallationProvider: { cliDiscovery.installations() }` ao `AssistantRouter`; expor `public let assistantCLIDiscovery: CachedAssistantCLIDiscovery` para os Ajustes poderem invalidar. Em `SettingsSections.swift`, o `save()` da IA (procure `private func save()` dentro de `GeneralSettingsView`) chama `assistantCLIDiscovery?.invalidate()` logo depois de `settingsStore.save(draft)`.

- [ ] Registrar a data das flags. Acima de `AssistantCLICommand.make` (`AssistantCLITextAssistant.swift:73-79`), acrescentar:
      ```swift
      // Conferido em 2026-09-01 contra os binários instalados nesta máquina:
      // `codex exec --json`, `claude --print --output-format json`,
      // `opencode --pure run --format json`. As flags existem; o defeito que
      // fazia o CLI parecer mudo era o stderr descartado, não o argv.
      ```
      O conjunto que trava o argv continua como está.

- [ ] Rodar e ver passar:
      ```bash
      swift test --package-path Packages/UNISync
      ```
      Esperado: suíte verde, e o `cliFailureShowsStderr` da Task 6 pode ser reabilitado agora:
      ```bash
      swift test --package-path Packages/UNIShell --filter AssistantFailureTests
      ```

- [ ] Provar por mutação: devolva `Data()` em `standardErrorTail` e confirme que `processFailureCarriesStderr` e `cliFailureShowsStderr` falham; desfaça. Faça `installations()` sempre varrer e confirme que `scansOncePerWindow` falha; desfaça.

- [ ] Commit:
      ```bash
      git add -A && git commit -m "fix: cache de 60 s na descoberta de CLIs e stderr que chega na tela

A varredura acontecia a cada pergunta e a causa real da falha ia para
/dev/null. Spec 1.6.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
      ```

---

### Task 12: Coordenadores OAuth viram `actor` (spec 1.6)

`LiteLLMOAuthCoordinator` (`:25-26`) e `AssistantProviderOAuthCoordinator` (`:37-38`) são `@MainActor`: toda chamada remota passa pela thread de interface para ler ou renovar token.

**Files**
- Modify `Packages/UNISync/Sources/UNISync/LiteLLMOAuthCoordinator.swift`
- Modify `Packages/UNISync/Sources/UNISync/AssistantProviderOAuthCoordinator.swift`
- Modify `Packages/UNIShell/Sources/UNIShell/Windows/SettingsSections.swift`
- Modify `Packages/UNISync/Tests/UNISyncTests/LiteLLMOAuthTests.swift`, `.../AssistantProviderOAuthTests.swift`

**Interfaces**
- Produces:
  ```swift
  @MainActor @Observable
  public final class LiteLLMOAuthSessionState {
      public private(set) var status: LiteLLMOAuthStatus
      public func apply(_ status: LiteLLMOAuthStatus)
  }

  public actor LiteLLMOAuthCoordinator: OpenAICompatibleOAuthTokenProviding {
      public init(sessionState: LiteLLMOAuthSessionState)
      public func refreshStatus(endpoint: URL, credentialID: String) async
      public func start(endpoint: URL, credentialID: String) async throws
      public func signOut(endpoint: URL, credentialID: String) async
      public func hasAccessToken(for credentialID: String, endpoint: URL) async -> Bool
      public func accessToken(for credentialID: String, endpoint: URL) async throws -> String?
  }

  @MainActor @Observable
  public final class AssistantProviderOAuthSessionState {
      public private(set) var status: AssistantProviderOAuthStatus
      public func apply(_ status: AssistantProviderOAuthStatus)
  }

  public actor AssistantProviderOAuthCoordinator:
      AssistantProviderOAuthAuthorizing, AssistantProviderOAuthTokenProviding {
      public init(sessionState: AssistantProviderOAuthSessionState)
      // mesmos métodos públicos de hoje (`:68`, `:92`, `:140`, `:147`, `:167`, `:191`, `:206`)
  }
  ```

**Steps**

- [ ] Escrever o teste que falha. Acrescentar a `Packages/UNISync/Tests/UNISyncTests/AssistantProviderOAuthTests.swift`:
      ```swift
      @Test("o token é lido fora do ator principal, e o estado chega à interface")
      func tokenReadHappensOffMainActor() async throws {
          let state = await AssistantProviderOAuthSessionState()
          let coordinator = AssistantProviderOAuthCoordinator(sessionState: state)
          let configuration = AssistantProviderOAuthConfiguration(kind: .xAI, model: "grok-4.6")

          // Sem sessão guardada, a consulta é barata e não toca em rede nem na
          // thread de interface. Se o coordenador voltar a ser @MainActor, esta
          // chamada precisa de `await MainActor.run` e o teste não compila.
          let present = await coordinator.hasAccessToken(for: configuration)
          #expect(!present)

          await coordinator.refreshStatus(configuration: configuration)
          let status = await MainActor.run { state.status }
          #expect(status != .idle)
      }
      ```

- [ ] Rodar e ver falhar:
      ```bash
      swift test --package-path Packages/UNISync --filter AssistantProviderOAuthTests
      ```
      Esperado: `cannot find 'AssistantProviderOAuthSessionState' in scope`.

- [ ] Converter `AssistantProviderOAuthCoordinator`. Trocar `@MainActor public final class` (linhas 37–38) por `public actor`, apagar `public private(set) var status` (linha 39) e guardar `private let sessionState: AssistantProviderOAuthSessionState`. Todo ponto que hoje escreve `status = …` passa a:
      ```swift
      private func publish(_ status: AssistantProviderOAuthStatus) async {
          await MainActor.run { self.sessionState.apply(status) }
      }
      ```
      Onde o coordenador apresentar UI do sistema (login por navegador/dispositivo), o salto explícito para `MainActor.run` fica **no ponto da apresentação**, não no tipo inteiro: era esse o custo que fazia toda chamada remota atravessar a interface.

- [ ] Criar o estado observável, no mesmo arquivo:
      ```swift
      /// O que Ajustes desenha. Só status — nunca token, nunca endpoint com
      /// credencial. O ator publica; a tela observa.
      @MainActor
      @Observable
      public final class AssistantProviderOAuthSessionState {
          public private(set) var status: AssistantProviderOAuthStatus = .idle
          public init() {}
          public func apply(_ status: AssistantProviderOAuthStatus) { self.status = status }
      }
      ```

- [ ] Repetir para `LiteLLMOAuthCoordinator` (linhas 25–29 e todos os pontos que escrevem `status`).

- [ ] Ajustar a composição e os Ajustes. Em `AppComposition.make` (linhas 151–152):
      ```swift
      let liteLLMOAuthState = LiteLLMOAuthSessionState()
      let liteLLMOAuth = LiteLLMOAuthCoordinator(sessionState: liteLLMOAuthState)
      let assistantProviderOAuthState = AssistantProviderOAuthSessionState()
      let assistantProviderOAuth = AssistantProviderOAuthCoordinator(sessionState: assistantProviderOAuthState)
      ```
      e expor os dois estados em `AppComposition` (`public let liteLLMOAuthState: LiteLLMOAuthSessionState`, idem para o outro). Em `SettingsSections.swift`, toda leitura de `coordinator.status` vira leitura do estado; toda chamada de método do coordenador ganha `await`.

- [ ] Rodar e ver passar:
      ```bash
      swift test --package-path Packages/UNISync
      swift test --package-path Packages/UNIShell
      xcodegen generate && xcodebuild -project OkamiUNI.xcodeproj -scheme OkamiUNI -configuration Debug build 2>&1 | grep -E "error:|BUILD"
      ```

- [ ] Commit:
      ```bash
      git add -A && git commit -m "refactor: coordenadores OAuth viram atores

Ler ou renovar token deixa de passar pela thread de interface; Ajustes
observa um estado publicado, sem tocar em token. Spec 1.6.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
      ```

---

### Task 13: A cópia deixa de mentir (spec 1.2)

`AssistantScope.footer` diz "Usa todas as caixas e a agenda carregadas neste Mac" (`AssistantPanel.swift:113`) e a espera diz "Lendo o contexto local…" (`:572`) com Grok selecionado. `IntelligencePresentation.scopeLabel` dizia "· local".

**Files**
- Modify `Packages/UNIShell/Sources/UNIShell/Inbox/AssistantPanel.swift` (`:110-115`, `:567-578`)
- Modify `Packages/UNIShell/Sources/UNIShell/Inbox/ReaderIntelligencePopover.swift` (título do popover)
- Modify `Packages/UNIShell/Sources/UNIShell/Inbox/DashboardScreen.swift` (rodapé do campo)
- Modify `Packages/UNIShell/Sources/UNIShell/Windows/SettingsSections.swift` (`:282-283`, `:332`, `:1719-1736`)
- Modify `Packages/UNIShell/Tests/UNIShellTests/AssistantPanelTests.swift`

**Steps**

- [ ] Escrever o teste que falha. Acrescentar a `AssistantPanelTests.swift`:
      ```swift
      @Test("com provedor remoto, nenhuma superfície promete processamento local")
      func remoteDestinationNeverPromisesLocal() async throws {
          let destination = AssistantDestination(
              label: "Grok · xAI", detail: "Sai deste Mac para a xAI.", isLocal: false
          )
          let conversation = AssistantConversation(
              scope: .workspace,
              context: .init(subject: "Todo o OkamiUNI", sender: "2 contas"),
              destination: destination,
              engine: .init(supportsDraftReply: false, answer: { _ in "ok" })
          )
          let panel = AssistantPanel(conversation: conversation, onClose: {})
          let image = try #require(Render.snapshot(
              panel.environment(ThemeStore()),
              named: "assistant-panel-remote",
              size: CGSize(width: 360, height: 640),
              theme: .okami
          ))
          #expect(image.pixelsWide == 360)

          // A cópia é lógica pura e mora fora da View: o rodapé é o detail do
          // destino, e não há mais um texto fixo por escopo.
          #expect(AssistantScope.workspace.footer(for: destination) == "Sai deste Mac para a xAI.")
          #expect(AssistantScope.email.footer(for: destination) == "Sai deste Mac para a xAI.")
          #expect(AssistantScope.workspace.loadingLabel(for: destination) == "Falando com Grok · xAI…")

          let local = AssistantDestination(
              label: "Neste Mac", detail: "Nada sai deste Mac.", isLocal: true
          )
          #expect(AssistantScope.workspace.footer(for: local) == "Nada sai deste Mac.")
          #expect(AssistantScope.workspace.loadingLabel(for: local) == "Lendo o contexto neste Mac…")
      }
      ```

- [ ] Rodar e ver falhar:
      ```bash
      swift test --package-path Packages/UNIShell --filter AssistantPanelTests
      ```
      Esperado: `value of type 'AssistantScope' has no member 'footer(for:)'`.

- [ ] Implementar. Em `AssistantPanel.swift`, substituir `var footer: String` (linhas 110–115) por:
      ```swift
      /// O rodapé é o destino, não uma promessa fixa. Foi essa frase, com Grok
      /// selecionado, que motivou a spec.
      func footer(for destination: AssistantDestination) -> String { destination.detail }

      func loadingLabel(for destination: AssistantDestination) -> String {
          destination.isLocal
              ? "Lendo o contexto neste Mac…"
              : "Falando com \(destination.label)…"
      }
      ```
      O `loadingBand` (linha 567) passa a usar `conversation.scope.loadingLabel(for: conversation.destination)`; o composer (linha 620) usa `conversation.scope.footer(for: conversation.destination)`.

- [ ] Varrer o resto da cópia:
      ```bash
      git grep -n -i 'neste Mac\|processamento local\|contexto local\|assistente local\|IA local\|Nada sai' -- 'Packages/*/Sources' 'App'
      ```
      Cada ocorrência que **não** consulta `AssistantDestination.isLocal` é corrigida:
      - `SettingsSections.swift:282-283` — a `SettingsNotice` de "Processamento local" continua, mas só no ramo `.foundationModels` (já é o caso) e o texto passa a "Perguntas e escrita usam o Foundation Models deste Mac. A análise automática de mensagens segue a rota escolhida abaixo." (a rota deixa de ser sempre local na Task 14).
      - `SettingsSections.swift:332` — o texto do `assistantRoutingNotice` perde a promessa sobre o TL;DR: "Este é o destino usado quando você aciona Resumo, Pontos-chave, Insights ou Gerar resposta."
      - `SettingsSections.swift:1719-1736` — `interactiveProviderLabel` é apagado; seus três chamadores (`:337`, `InboxScreen.swift:674`, `MessageWindow.swift:49`) passam a `AssistantDestination(settings: …).label`.
      - `ReaderIntelligencePopover` — o título do popover ganha `· \(conversation.destination.label)`.

- [ ] Rodar e ver passar:
      ```bash
      swift test --package-path Packages/UNIShell
      git grep -n 'Usa todas as caixas e a agenda carregadas neste Mac\|Lendo o contexto local' -- '*.swift' || echo "cópia mentirosa eliminada"
      ```

- [ ] Commit:
      ```bash
      git add -A && git commit -m "fix: a cópia do assistente diz para onde o email vai

Rodapé, espera, título do popover e Ajustes passam a ler
AssistantDestination. 'Nada sai deste Mac' só com Foundation Models.
Spec 1.2.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
      ```

---

### Task 14: Análise automática com opt-in e fila que pausa (spec 1.8)

A análise persistida é sempre `FoundationModelsMessageAnalyzer` (`AppComposition.swift:148`), independente do provedor — e é a única coisa do app que roda **sem** a pessoa pedir. Torná-la remota sem opt-in seria mandar cada mensagem recebida para um servidor.

> **Desvio consciente da spec:** ela diz "estado `paused(reason)` persistido em `sync_state`". A tabela `sync_state` tem `accountID TEXT NOT NULL REFERENCES account(id)` (`SyncDatabase.swift:231-239`) e chaves estrangeiras estão ligadas: **sem conta conectada não haveria onde gravar** — exatamente a lição já registrada em `docs/decisoes-de-engenharia.md` sobre `created_agenda_item`. E a fila é global, não por conta. A migração `v15` cria `analysis_queue_state`, de linha única.

**Files**
- Modify `Packages/UNISync/Sources/UNISync/AssistantSettings.swift` (`currentSchemaVersion` em `:430`; `migrated()` em `:465-485`; `CodingKeys`/`init(from:)`/`encode` em `:503-546`)
- Modify `Packages/UNISync/Sources/UNISync/Database/SyncDatabase.swift` (migração nova depois de `v14`, `:629-632`)
- Create `Packages/UNISync/Sources/UNISync/Database/AnalysisQueueState.swift`
- Create `Packages/UNISync/Sources/UNISync/RoutedMessageAnalyzer.swift`
- Create `Packages/UNISync/Sources/UNISync/TextAssistantMessageAnalyzer.swift`
- Modify `Packages/UNISync/Sources/UNISync/MessageIntelligenceCoordinator.swift` (`processPending` em `:88-160`)
- Modify `Packages/UNISync/Sources/UNISync/AppComposition.swift` (`:148`)
- Modify `Packages/UNIShell/Sources/UNIShell/Inbox/FolderSidebar.swift`, `Inbox/InboxScreen.swift`, `Windows/SettingsSections.swift`
- Create `Packages/UNISync/Tests/UNISyncTests/RoutedMessageAnalyzerTests.swift`
- Modify `Packages/UNISync/Tests/UNISyncTests/MessageIntelligenceCoordinatorTests.swift`, `.../AssistantSettingsTests.swift`

**Interfaces**
- Produces:
  ```swift
  public enum AutomaticAnalysisRoute: String, Codable, Sendable, Hashable, CaseIterable {
      case onDeviceOnly
      case configuredProvider
  }

  public struct RoutedMessageAnalyzer: MessageAnalyzing {
      public init(
          settingsStore: AssistantSettingsStore,
          onDevice: any MessageAnalyzing,
          configured: any MessageAnalyzing
      )
  }

  public struct TextAssistantMessageAnalyzer: MessageAnalyzing {
      public static let currentModelVersion = "text-assistant/message-analysis-v1"
      public init(assistant: any TextAssisting, availability: @escaping @Sendable () async -> AppleIntelligenceAvailability)
  }

  public enum AnalysisQueueState: Sendable, Hashable {
      case running
      case paused(reason: String)
  }

  public struct AnalysisQueueStateStore: Sendable {
      public init(database: SyncDatabase)
      public func state() throws -> AnalysisQueueState
      public func pause(reason: String, at date: Date) throws
      public func resume() throws
  }

  public extension MessageIntelligenceCoordinator {
      static let failuresBeforePause = 3
      func queueState() -> AnalysisQueueState
      func resumeAfterPause() async
  }
  ```

**Steps**

- [ ] Escrever os testes que falham. `Packages/UNISync/Tests/UNISyncTests/RoutedMessageAnalyzerTests.swift`:
      ```swift
      import Foundation
      import Testing
      import UNICore
      @testable import UNISync

      @Suite("Rota da análise automática")
      struct RoutedMessageAnalyzerTests {
          private func store(_ route: AutomaticAnalysisRoute) throws -> AssistantSettingsStore {
              let suite = "okamiuni.automatic-analysis.\(UUID().uuidString)"
              let defaults = try #require(UserDefaults(suiteName: suite))
              defaults.removePersistentDomain(forName: suite)
              let store = AssistantSettingsStore(defaults: defaults, key: "assistant")
              try store.save(.init(
                  provider: .openAICompatible,
                  openAICompatible: .init(
                      endpoint: "https://api.example.com/v1", model: "m",
                      credentialID: "primary", authenticationMode: .apiKey
                  ),
                  automaticAnalysis: route
              ))
              return store
          }

          private var input: MessageAnalysisInput {
              .init(
                  subject: "Revisão", sender: "Marina <marina@example.com>",
                  receivedAt: Date(timeIntervalSince1970: 1_788_000_000),
                  body: "Falamos amanhã às 15h.",
                  timeZone: TimeZone(identifier: "America/Sao_Paulo")!
              )
          }

          @Test("o padrão é a rota do dispositivo, mesmo com provedor remoto escolhido")
          func defaultsToOnDevice() async throws {
              #expect(AssistantSettings.default.automaticAnalysis == .onDeviceOnly)
              let onDevice = SpyMessageAnalyzer(modelVersion: "on-device")
              let configured = SpyMessageAnalyzer(modelVersion: "remoto")
              let analyzer = RoutedMessageAnalyzer(
                  settingsStore: try store(.onDeviceOnly),
                  onDevice: onDevice, configured: configured
              )
              _ = try await analyzer.analyze(input)
              #expect(onDevice.calls == 1)
              #expect(configured.calls == 0)
              #expect(analyzer.modelVersion == "on-device")
          }

          @Test("com opt-in, cada mensagem vai para o provedor configurado")
          func optInRoutesToConfigured() async throws {
              let onDevice = SpyMessageAnalyzer(modelVersion: "on-device")
              let configured = SpyMessageAnalyzer(modelVersion: "remoto")
              let analyzer = RoutedMessageAnalyzer(
                  settingsStore: try store(.configuredProvider),
                  onDevice: onDevice, configured: configured
              )
              _ = try await analyzer.analyze(input)
              #expect(configured.calls == 1)
              #expect(onDevice.calls == 0)
          }

          @Test("o JSON do provedor é validado com rigor, e evidência sem trecho literal cai")
          func strictJSONValidation() async throws {
              let spy = SpyTextAssistantForAnalysis()
              spy.result = """
              {"summary":"Marina propõe amanhã às 15h.",
               "category":"pessoal",
               "detectedEvent":{"title":"Conversa","evidence":"amanhã às 15h",
                                "startMinute":900,"endMinute":960,"dayOffset":1}}
              """
              let analyzer = TextAssistantMessageAnalyzer(assistant: spy, availability: { .available })
              let result = try await analyzer.analyze(input)
              #expect(result.summary == "Marina propõe amanhã às 15h.")
              #expect(result.detectedEvent != nil)
              #expect(result.modelVersion == TextAssistantMessageAnalyzer.currentModelVersion)

              spy.result = """
              {"summary":"Resumo","detectedEvent":{"title":"Reunião",
               "evidence":"terça que vem","startMinute":600,"endMinute":660,"dayOffset":3}}
              """
              let invented = try await analyzer.analyze(input)
              // "terça que vem" não é substring literal do corpo analisado.
              #expect(invented.detectedEvent == nil)
              #expect(invented.summary == "Resumo")

              spy.result = "isto não é JSON"
              await #expect(throws: MessageAnalysisError.self) {
                  _ = try await analyzer.analyze(input)
              }
          }
      }

      final class SpyMessageAnalyzer: MessageAnalyzing, @unchecked Sendable {
          let modelVersion: String
          private let lock = NSLock()
          private var count = 0
          var calls: Int { lock.withLock { count } }

          init(modelVersion: String) { self.modelVersion = modelVersion }

          func availability() async -> AppleIntelligenceAvailability { .available }

          func analyze(_ input: MessageAnalysisInput) async throws -> MessageAnalysisResult {
              lock.withLock { count += 1 }
              return .init(summary: "resumo", detectedEvent: nil, modelVersion: modelVersion)
          }
      }

      final class SpyTextAssistantForAnalysis: TextAssisting, @unchecked Sendable {
          let modelVersion = "spy/analysis"
          var result = "{}"
          func availability() async -> AppleIntelligenceAvailability { .available }
          func answer(question: String, in conversation: AssistantConversationSnapshot) async throws -> String { result }
          func transform(_ text: String, using action: WritingAction, context: AssistantMailContext?) async throws -> String { result }
      }
      ```
      E, em `MessageIntelligenceCoordinatorTests.swift`:
      ```swift
      @Test("três falhas de autenticação seguidas pausam a fila; nada cai para o Mac")
      func threeAuthFailuresPauseTheQueue() async throws {
          let database = try database()
          for index in 2...5 {
              try insertMessage(
                  id: "m\(index)", subject: "Assunto \(index)",
                  receivedAt: Date(timeIntervalSince1970: 1_788_000_000 + Double(index)),
                  database: database
              )
          }
          let analyzer = FailingAnalyzer(error: OpenAICompatibleTextAssistantError.authenticationFailed)
          let coordinator = MessageIntelligenceCoordinator(
              database: database, analyzer: analyzer, timeZone: { self.timeZone }
          )
          _ = await coordinator.processPending()

          #expect(analyzer.calls == MessageIntelligenceCoordinator.failuresBeforePause)
          #expect(await coordinator.queueState() == .paused(
              reason: OpenAICompatibleTextAssistantError.authenticationFailed.errorDescription!
          ))

          // A pausa sobrevive a uma nova instância: ela está no banco.
          let reopened = MessageIntelligenceCoordinator(
              database: database, analyzer: analyzer, timeZone: { self.timeZone }
          )
          #expect(await reopened.processPending() == 0)
          #expect(analyzer.calls == MessageIntelligenceCoordinator.failuresBeforePause)

          await reopened.resumeAfterPause()
          #expect(await reopened.queueState() == .running)
          #expect(await reopened.processPending() >= 0)
          #expect(analyzer.calls > MessageIntelligenceCoordinator.failuresBeforePause)
      }

      final class FailingAnalyzer: MessageAnalyzing, @unchecked Sendable {
          let modelVersion = "failing/v1"
          private let lock = NSLock()
          private var count = 0
          private let error: any Error
          var calls: Int { lock.withLock { count } }
          init(error: any Error) { self.error = error }
          func availability() async -> AppleIntelligenceAvailability { .available }
          func analyze(_ input: MessageAnalysisInput) async throws -> MessageAnalysisResult {
              lock.withLock { count += 1 }
              throw error
          }
      }
      ```
      E, em `AssistantSettingsTests.swift`:
      ```swift
      @Test("a v5 preenche a rota da análise sem mudar o provedor")
      func migratesToSchemaFive() throws {
          let legacy = """
          {"schemaVersion":4,"provider":"cli","openAICompatible":{"endpoint":"","model":"",
           "credentialID":"openai-compatible-default","authenticationMode":"apiKey"},
           "providerOAuth":{"kind":"codex","model":"","credentialID":"provider-oauth-codex"},
           "cli":{"kind":"openCode"},"behavior":{"tone":"natural","detail":"adaptive",
           "language":"portugueseBrazil","format":"adaptive","suggestNextSteps":true,
           "questionsInstructions":"","writingInstructions":""},"additionalInstructions":""}
          """
          let decoded = try JSONDecoder().decode(AssistantSettings.self, from: Data(legacy.utf8))
          let migrated = try decoded.migrated()
          #expect(migrated.schemaVersion == 5)
          #expect(AssistantSettings.currentSchemaVersion == 5)
          #expect(migrated.provider == .cli)
          #expect(migrated.automaticAnalysis == .onDeviceOnly)
      }
      ```

- [ ] Rodar e ver falhar:
      ```bash
      swift test --package-path Packages/UNISync --filter 'RoutedMessageAnalyzerTests|MessageIntelligenceCoordinatorTests|AssistantSettingsTests'
      ```
      Esperado: `cannot find 'AutomaticAnalysisRoute' in scope`, `extra argument 'automaticAnalysis' in call`, `has no member 'queueState'`.

- [ ] Acrescentar a preferência. Em `AssistantSettings.swift`, antes de `AssistantSettings`:
      ```swift
      /// Para onde vai a análise que roda **sem** a pessoa pedir.
      ///
      /// Separada do provedor interativo de propósito: escolher Grok para
      /// responder perguntas não pode significar mandar cada mensagem recebida
      /// para a xAI em segundo plano.
      public enum AutomaticAnalysisRoute: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
          case onDeviceOnly
          case configuredProvider

          public var id: String { rawValue }
      }
      ```
      e, no corpo de `AssistantSettings`:
      ```swift
      public static let currentSchemaVersion = 5
      // …
      public var automaticAnalysis: AutomaticAnalysisRoute
      ```
      com `automaticAnalysis: AutomaticAnalysisRoute = .onDeviceOnly` no `init`, `case automaticAnalysis` em `CodingKeys`, e no `init(from:)`:
      ```swift
      // Documento v4 não conhecia a rota. `onDeviceOnly` é o único padrão que
      // não muda o comportamento de quem já tinha o app instalado.
      automaticAnalysis = try values.decodeIfPresent(
          AutomaticAnalysisRoute.self, forKey: .automaticAnalysis
      ) ?? .onDeviceOnly
      ```
      e `try values.encode(automaticAnalysis, forKey: .automaticAnalysis)` no `encode`.

- [ ] Migração `v15`. Em `SyncDatabase.swift`, logo depois do bloco `v14` (linha 629):
      ```swift
      // A v15: o estado da fila de análise automática. Tabela própria, e não
      // `sync_state`, porque `sync_state.accountID` tem REFERENCES account(id)
      // e a fila é global — a mesma lição de `created_agenda_item` na v5.
      migrator.registerMigration("v15") { db in
          try db.execute(sql: """
              CREATE TABLE analysis_queue_state (
                id TEXT PRIMARY KEY NOT NULL,
                isPaused INTEGER NOT NULL DEFAULT 0,
                reason TEXT,
                pausedAt DOUBLE
              )
              """)
      }
      ```

- [ ] Criar o estado. `Packages/UNISync/Sources/UNISync/Database/AnalysisQueueState.swift`:
      ```swift
      import Foundation
      import GRDB

      /// A fila de análise automática nunca cai para o Mac em silêncio: ela
      /// para, com o motivo na tela, e só volta por um clique.
      public enum AnalysisQueueState: Sendable, Hashable {
          case running
          case paused(reason: String)

          public var isPaused: Bool {
              if case .paused = self { return true }
              return false
          }

          public var reason: String? {
              if case let .paused(reason) = self { return reason }
              return nil
          }
      }

      struct AnalysisQueueStateRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
          static let databaseTableName = "analysis_queue_state"
          static let singletonID = "default"

          var id: String
          var isPaused: Bool
          var reason: String?
          var pausedAt: Date?
      }

      public struct AnalysisQueueStateStore: Sendable {
          private let database: SyncDatabase

          public init(database: SyncDatabase) { self.database = database }

          public func state() throws -> AnalysisQueueState {
              try database.pool.read { db in
                  guard let record = try AnalysisQueueStateRecord.fetchOne(
                      db, key: AnalysisQueueStateRecord.singletonID
                  ), record.isPaused, let reason = record.reason else {
                      return .running
                  }
                  return .paused(reason: reason)
              }
          }

          public func pause(reason: String, at date: Date) throws {
              try database.pool.write { db in
                  try AnalysisQueueStateRecord(
                      id: AnalysisQueueStateRecord.singletonID,
                      isPaused: true, reason: reason, pausedAt: date
                  ).save(db)
              }
          }

          public func resume() throws {
              try database.pool.write { db in
                  try AnalysisQueueStateRecord(
                      id: AnalysisQueueStateRecord.singletonID,
                      isPaused: false, reason: nil, pausedAt: nil
                  ).save(db)
              }
          }
      }
      ```

- [ ] Criar o roteador de análise. `Packages/UNISync/Sources/UNISync/RoutedMessageAnalyzer.swift`:
      ```swift
      import Foundation
      import UNICore

      /// Escolhe o motor **por chamada**, lendo o snapshot das preferências.
      /// Quando o provedor configurado é o Foundation Models, as duas rotas
      /// coincidem e o app não paga nada por isso.
      public struct RoutedMessageAnalyzer: MessageAnalyzing {
          private let settingsStore: AssistantSettingsStore
          private let onDevice: any MessageAnalyzing
          private let configured: any MessageAnalyzing

          public init(
              settingsStore: AssistantSettingsStore,
              onDevice: any MessageAnalyzing,
              configured: any MessageAnalyzing
          ) {
              self.settingsStore = settingsStore
              self.onDevice = onDevice
              self.configured = configured
          }

          public var modelVersion: String { current.modelVersion }

          public func availability() async -> AppleIntelligenceAvailability {
              await current.availability()
          }

          public func analyze(_ input: MessageAnalysisInput) async throws -> MessageAnalysisResult {
              try await current.analyze(input)
          }

          private var current: any MessageAnalyzing {
              let settings = settingsStore.snapshot()
              switch settings.automaticAnalysis {
              case .onDeviceOnly: return onDevice
              case .configuredProvider:
                  return settings.provider == .foundationModels ? onDevice : configured
              }
          }
      }
      ```

- [ ] Criar o analisador por JSON. `Packages/UNISync/Sources/UNISync/TextAssistantMessageAnalyzer.swift`:
      ```swift
      import Foundation
      import UNICore

      /// Pede ao `TextAssisting` roteado um JSON fechado e o valida com
      /// `Decodable` estrito. O contrato de evidência é o mesmo do motor local:
      /// data só sobrevive quando `evidence` é trecho **literal** do texto
      /// analisado — o modelo não pode transformar a data de recebimento em
      /// compromisso inventado.
      public struct TextAssistantMessageAnalyzer: MessageAnalyzing {
          public static let currentModelVersion = "text-assistant/message-analysis-v1"
          public let modelVersion = TextAssistantMessageAnalyzer.currentModelVersion

          private let assistant: any TextAssisting
          private let availabilityProbe: @Sendable () async -> AppleIntelligenceAvailability

          public init(
              assistant: any TextAssisting,
              availability: @escaping @Sendable () async -> AppleIntelligenceAvailability
          ) {
              self.assistant = assistant
              self.availabilityProbe = availability
          }

          public func availability() async -> AppleIntelligenceAvailability {
              await availabilityProbe()
          }

          public func analyze(_ input: MessageAnalysisInput) async throws -> MessageAnalysisResult {
              let raw = try await assistant.answer(
                  question: Self.question(for: input),
                  in: AssistantConversationSnapshot(
                      mailContext: .email(AssistantEmailContext(
                          subject: input.subject,
                          sender: input.sender,
                          sentAt: input.receivedAt,
                          body: input.body
                      ))
                  )
              )
              guard let data = Self.jsonPayload(in: raw) else {
                  throw MessageAnalysisError.invalidResponse("A resposta não continha JSON.")
              }
              let decoder = JSONDecoder()
              guard let output = try? decoder.decode(Output.self, from: data) else {
                  throw MessageAnalysisError.invalidResponse("O JSON não bate com o contrato pedido.")
              }
              let summary = output.summary.trimmingCharacters(in: .whitespacesAndNewlines)
              guard !summary.isEmpty else {
                  throw MessageAnalysisError.invalidResponse("O resumo veio vazio.")
              }
              return MessageAnalysisResult(
                  summary: summary,
                  detectedEvent: output.detectedEvent.flatMap {
                      $0.validated(against: input)
                  },
                  modelVersion: modelVersion,
                  category: output.category.flatMap(MailCategory.init(rawValue:))
              )
          }

          static func question(for input: MessageAnalysisInput) -> String {
              """
              Analise o e-mail em <untrusted-app-context> e devolva SOMENTE um
              objeto JSON, sem texto antes ou depois, sem bloco de código, com
              exatamente estas chaves:
              {"summary": String,
               "category": "trabalho"|"pessoal"|"financeiro"|"compras"|"newsletter"|"social"|null,
               "detectedEvent": {"title": String, "evidence": String,
                                 "dayOffset": Int, "startMinute": Int, "endMinute": Int} | null}
              `summary` tem 1 ou 2 frases e começa pelo conteúdo, não por
              metadados. `detectedEvent` só existe quando o texto marca data e
              hora explícitas; `evidence` precisa ser um trecho **literal**,
              copiado caractere a caractere do corpo. Se não houver, use null.
              `dayOffset` é relativo à data de recebimento no fuso
              \(input.timeZone.identifier); `startMinute` e `endMinute` são
              minutos desde a meia-noite.
              """
          }

          /// O modelo às vezes embrulha o JSON em ```json. Pegar do primeiro `{`
          /// ao último `}` é mais honesto do que exigir formatação perfeita — e
          /// continua estrito, porque o `Decodable` recusa qualquer outra coisa.
          static func jsonPayload(in raw: String) -> Data? {
              guard let start = raw.firstIndex(of: "{"),
                    let end = raw.lastIndex(of: "}"),
                    start < end
              else { return nil }
              return Data(raw[start...end].utf8)
          }

          private struct Output: Decodable {
              struct Event: Decodable {
                  let title: String
                  let evidence: String
                  let dayOffset: Int
                  let startMinute: Int
                  let endMinute: Int

                  /// A mesma regra do motor local: sem trecho literal, o
                  /// compromisso é descartado inteiro.
                  func validated(against input: MessageAnalysisInput) -> DetectedEvent? {
                      let evidence = evidence.trimmingCharacters(in: .whitespacesAndNewlines)
                      guard !evidence.isEmpty, input.body.contains(evidence) else { return nil }
                      guard (0...31).contains(dayOffset),
                            (0..<1_440).contains(startMinute),
                            (0...1_440).contains(endMinute),
                            endMinute > startMinute
                      else { return nil }
                      return DetectedEvent(
                          title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                          dayOffset: dayOffset,
                          startMinute: startMinute,
                          endMinute: endMinute
                      )
                  }
              }

              let summary: String
              let category: String?
              let detectedEvent: Event?
          }
      }
      ```
      **Antes de escrever**, confira a assinatura real de `DetectedEvent.init` em `Packages/UNICore/Sources/UNICore/DetectedEvent.swift` e a de `MailCategory` em `.../MailCategory.swift`, e use exatamente os rótulos que existirem lá; o `Output.Event.validated` acima assume `title/dayOffset/startMinute/endMinute`.

- [ ] Pausar a fila. Em `MessageIntelligenceCoordinator.swift`:
      ```swift
      /// Três seguidas. Uma falha é ruído de rede; três é configuração errada,
      /// e insistir manda a caixa inteira para um endpoint que recusa.
      public static let failuresBeforePause = 3

      private let queueStateStore: AnalysisQueueStateStore
      private var consecutivePolicyFailures = 0

      public func queueState() -> AnalysisQueueState {
          (try? queueStateStore.state()) ?? .running
      }

      /// "Tentar de novo" da barra lateral. Zera o contador e destrava a fila.
      public func resumeAfterPause() async {
          try? queueStateStore.resume()
          consecutivePolicyFailures = 0
          _ = await processPending()
      }

      /// Auth e rede são condições **do ambiente**, não da mensagem: marcar a
      /// mensagem como falha tornaria permanente uma chave que ainda vai ser
      /// corrigida em Ajustes.
      static func isEnvironmentFailure(_ error: any Error) -> Bool {
          switch error {
          case let error as OpenAICompatibleTextAssistantError:
              switch error {
              case .missingAPIKey, .missingOAuthAuthorization, .oauthProviderUnavailable,
                   .authenticationFailed, .rateLimited, .timedOut, .connectionFailed, .server:
                  return true
              case .invalidResponse:
                  return false
              }
          case let error as AssistantProviderOAuthTextAssistantError:
              switch error {
              case .missingAuthorization, .authenticationFailed, .subscriptionNotEligible,
                   .rateLimited, .timedOut, .connectionFailed, .redirectRefused,
                   .upgradeRequired, .server, .managedByCodexRuntime:
                  return true
              case .invalidResponse:
                  return false
              }
          case let error as AssistantCLITextAssistantError:
              switch error {
              case .executableNotFound, .executableNotAllowed, .processFailed, .timedOut:
                  return true
              case .outputTooLarge, .invalidResponse:
                  return false
              }
          case is AssistantProviderOAuthError:
              return true
          case let error as URLError:
              return error.code != .cancelled
          default:
              return false
          }
      }
      ```
      e, dentro de `processPending`, logo depois da guarda de `isProcessing` (linha 89):
      ```swift
      guard case .running = queueState() else { return 0 }
      ```
      e no `catch` genérico (linhas 147–157):
      ```swift
      } catch {
          if Self.isEnvironmentFailure(error) {
              consecutivePolicyFailures += 1
              // O estado `processing` desta mensagem é retomável; ela não é
              // marcada como falha porque o defeito não é dela.
              if consecutivePolicyFailures >= Self.failuresBeforePause {
                  let reason = (error as? any LocalizedError)?.errorDescription
                      ?? error.localizedDescription
                  try? queueStateStore.pause(reason: reason, at: Date())
                  Self.log.error("Fila de análise pausada: \(reason, privacy: .public)")
                  break
              }
              continue
          }
          consecutivePolicyFailures = 0
          do {
              _ = try store.markFailed(
                  work, modelVersion: analyzer.modelVersion, error: error.localizedDescription
              )
          } catch {
              Self.log.error("Não foi possível registrar falha da inteligência: \(error)")
          }
      }
      ```
      Um sucesso zera `consecutivePolicyFailures` (logo depois de `if saved { completed += 1 }`).

- [ ] Compor. Em `AppComposition.make`, trocar a linha 148:
      ```swift
      let foundationModelsAnalyzer = FoundationModelsMessageAnalyzer()
      // Só existe depois do router; ver a ordem em Task 10.
      let analyzer = RoutedMessageAnalyzer(
          settingsStore: assistantSettings,
          onDevice: foundationModelsAnalyzer,
          configured: TextAssistantMessageAnalyzer(
              assistant: router,
              availability: { await router.availability() }
          )
      )
      ```

- [ ] Mostrar a pausa. Em `FolderSidebar.swift`, abaixo do `IntelligenceFooter`:
      ```swift
      /// "Nenhum controle mudo": a fila parada aparece com o motivo e um botão
      /// que religa de verdade, como a fila de saída do Marco 3.
      struct AnalysisPausedBand: View {
          @Environment(\.theme) private var theme
          @Environment(\.displayScale) private var displayScale

          let reason: String
          let onRetry: () -> Void

          var body: some View {
              VStack(alignment: .leading, spacing: 6) {
                  Text("ANÁLISE PAUSADA")
                      .capsLabel(size: 8.5)
                  Text(reason)
                      .font(theme.sans.font(size: 11.5))
                      .foregroundStyle(theme.ink3.color)
                      .fixedSize(horizontal: false, vertical: true)
                  ChromeButton("Tentar de novo", appearance: .outlined,
                               size: 11, height: 24, horizontalPadding: 9,
                               action: onRetry)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 12)
              .padding(.vertical, 10)
              .background(theme.surface2.color)
              .hairline(theme.line, edges: .top)
              .accessibilityIdentifier("analysis-paused-band")
          }
      }
      ```
      `InboxScreen` recebe `let analysisPause: (reason: String, retry: () -> Void)?` e desenha a faixa quando não for `nil`; `App/OkamiUNIApp.swift` a alimenta de `composition.intelligence?.queueState()`.

- [ ] Toggle nos Ajustes. Em `SettingsSections.swift`, dentro de `assistantCard`, depois de `assistantRoutingNotice`, só para destino remoto:
      ```swift
      if !AssistantDestination(settings: draft).isLocal {
          SettingsLabeledRow(label: "Análise automática") {
              Toggle(isOn: Binding(
                  get: { draft.automaticAnalysis == .configuredProvider },
                  set: { draft.automaticAnalysis = $0 ? .configuredProvider : .onDeviceOnly }
              )) {
                  Text("Analisar mensagens novas automaticamente com \(AssistantDestination(settings: draft).label)")
                      .font(theme.sans.font(size: 12))
                      .foregroundStyle(theme.ink2.color)
              }
              .toggleStyle(.switch)
              .labelsHidden()
          }
          SettingsNotice(
              symbol: "network",
              title: "Cada mensagem recebida sai deste Mac",
              text: "Com isto ligado, assunto e corpo de cada mensagem nova saem deste Mac para \(AssistantDestination(settings: draft).label). Desligado, o resumo automático continua sendo feito pelo Foundation Models."
          )
      }
      ```

- [ ] Rodar e ver passar:
      ```bash
      swift test --package-path Packages/UNISync
      swift test --package-path Packages/UNIShell
      xcodegen generate && xcodebuild -project OkamiUNI.xcodeproj -scheme OkamiUNI -configuration Debug build 2>&1 | grep -E "error:|BUILD"
      ```

- [ ] Provar por mutação: troque `?? .onDeviceOnly` por `?? .configuredProvider` no `init(from:)` e confirme que `migratesToSchemaFive` e `defaultsToOnDevice` falham; desfaça. Troque `failuresBeforePause` para 30 e confirme que `threeAuthFailuresPauseTheQueue` falha; desfaça. Apague a checagem `input.body.contains(evidence)` e confirme que `strictJSONValidation` falha; desfaça.

- [ ] Commit:
      ```bash
      git add -A && git commit -m "feat: análise automática remota é opt-in, e a fila pausa

Schema v5 com automaticAnalysis = .onDeviceOnly, RoutedMessageAnalyzer,
TextAssistantMessageAnalyzer com JSON estrito e evidência literal, e
pausa persistida depois de três falhas de ambiente. Spec 1.8.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
      ```

---

### Task 15: Golden do prompt de workspace e a cobertura que faltava do roteador (spec 1.9)

`AssistantRouterTests` não cobre `.cli` nem `.providerOAuth`, e não existe golden do que sai da máquina no contexto de workspace — acrescentar campo novo ao contexto hoje não quebra nada.

**Files**
- Create `Packages/UNISync/Tests/UNISyncTests/Golden/workspace-prompt.txt`
- Modify `Packages/UNISync/Tests/UNISyncTests/AssistantPromptTests.swift`
- Modify `Packages/UNISync/Tests/UNISyncTests/AssistantRouterTests.swift`
- Modify `Packages/UNISync/Package.swift` (declarar o recurso do golden)

**Interfaces**
- Consumes: `AssistantPrompt.render(_:budget:)` (Task 4), `AssistantRouter` (Tasks 4 e 10), `CachedAssistantCLIDiscovery` (Task 11).

**Steps**

- [ ] Declarar o recurso. Em `Packages/UNISync/Package.swift`, no alvo de testes:
      ```swift
      .testTarget(
          name: "UNISyncTests",
          dependencies: ["UNISync"],
          resources: [.copy("Golden")]
      )
      ```
      (mantenha as dependências que já estiverem lá; só acrescente `resources:`.)

- [ ] Escrever o golden que falha. Em `AssistantPromptTests.swift`:
      ```swift
      @Test("o prompt de workspace é congelado: campo novo no contexto quebra o golden")
      func workspacePromptGolden() throws {
          let workspace = AssistantWorkspaceContext(
              accounts: ["Marcos · marcos@example.com · example.com"],
              emailCount: 2,
              unreadCount: 1,
              mailboxes: [.init(name: "Hoje", totalCount: 2, unreadCount: 1)],
              emails: [
                  .init(
                      id: "m1", account: "marcos@example.com", mailbox: "Hoje",
                      isRead: false, isFlagged: true,
                      subject: "Revisão do contrato", sender: "Marina <marina@example.com>",
                      recipients: ["marcos@example.com"],
                      sentAt: Date(timeIntervalSince1970: 1_788_000_000),
                      snippet: "Consegue olhar hoje?"
                  ),
                  .init(
                      id: "m2", account: "marcos@example.com", mailbox: "Hoje",
                      isRead: true, isFlagged: false,
                      subject: "Nota fiscal", sender: "Financeiro <fin@example.com>",
                      recipients: ["marcos@example.com"],
                      sentAt: Date(timeIntervalSince1970: 1_788_003_600),
                      snippet: "Segue anexo."
                  ),
              ],
              agenda: [
                  .init(
                      title: "Comitê", date: Date(timeIntervalSince1970: 1_788_000_000),
                      startMinute: 570, endMinute: 630,
                      account: "marcos@example.com", place: "Sala 2"
                  ),
              ],
              pendingItems: [.init(text: "Confirmar sala", account: "marcos@example.com")]
          )
          let rendered = AssistantPrompt.render(workspace, budget: .configured)
          let url = try #require(Bundle.module.url(
              forResource: "workspace-prompt", withExtension: "txt", subdirectory: "Golden"
          ))
          let golden = try String(contentsOf: url, encoding: .utf8)
          #expect(rendered == golden)
      }
      ```

- [ ] Rodar e ver falhar:
      ```bash
      swift test --package-path Packages/UNISync --filter AssistantPromptTests
      ```
      Esperado: o `#require` do recurso falha — o arquivo não existe.

- [ ] Gerar o golden **uma vez**, conferindo com os olhos antes de gravar. Acrescente temporariamente `print(rendered)` no teste, rode com `--filter workspacePromptGolden`, leia a saída inteira (ela tem de conter `<workspace-summary>`, `<workspace-emails priority-first="flagged-unread-recent">`, `<workspace-agenda chronological="true">` e `<workspace-pending-items>`), e só então grave o texto em `Packages/UNISync/Tests/UNISyncTests/Golden/workspace-prompt.txt`. Remova o `print`.

- [ ] Provar que o golden serve para alguma coisa: acrescente um campo qualquer ao render (por exemplo `threadCount:` dentro de `<email>`) e confirme que o teste falha; desfaça.

- [ ] Cobrir `.cli` no roteador. Em `AssistantRouterTests.swift`:
      ```swift
      @Test("cada CLI da allowlist chega ao executor com o argv dele")
      @available(macOS 26.0, *)
      func routesToEachCLIKind() async throws {
          for kind in AssistantCLIKind.allCases {
              let suite = "okamiuni.assistant-router-cli.\(UUID().uuidString)"
              let defaults = try #require(UserDefaults(suiteName: suite))
              defaults.removePersistentDomain(forName: suite)
              defer { defaults.removePersistentDomain(forName: suite) }

              let settingsStore = AssistantSettingsStore(defaults: defaults, key: "assistant")
              try settingsStore.save(.init(provider: .cli, cli: .init(kind: kind)))
              let executor = RecordingAssistantCLIExecutor(output: kind)
              let router = AssistantRouter(
                  settingsStore: settingsStore,
                  credentialStore: InMemoryAssistantCredentialStore(),
                  cliInstallationProvider: {
                      AssistantCLIKind.allCases.map {
                          .init(kind: $0, executablePath: "/usr/bin/true")
                      }
                  },
                  cliExecutor: executor
              )
              _ = try await router.answer(question: "Qual é a prioridade?", in: conversation)
              let request = try #require(executor.lastRequest)
              #expect(request.executableURL.path == "/usr/bin/true")
              #expect(request.timeout == 120)
              #expect(!request.arguments.isEmpty)
          }
      }

      @Test("codex sem binário instalado devolve executableNotFound")
      @available(macOS 26.0, *)
      func codexSubscriptionWithoutBinary() async throws {
          let suite = "okamiuni.assistant-router-codex.\(UUID().uuidString)"
          let defaults = try #require(UserDefaults(suiteName: suite))
          defaults.removePersistentDomain(forName: suite)
          defer { defaults.removePersistentDomain(forName: suite) }

          let settingsStore = AssistantSettingsStore(defaults: defaults, key: "assistant")
          try settingsStore.save(.init(
              provider: .providerOAuth,
              providerOAuth: .init(kind: .codex, model: "gpt-5-codex")
          ))
          let router = AssistantRouter(
              settingsStore: settingsStore,
              credentialStore: InMemoryAssistantCredentialStore(),
              providerOAuthTokenProvider: AlwaysAuthorizedProviderOAuth(),
              cliInstallationProvider: { [.init(kind: .codex, executablePath: nil)] }
          )
          await #expect(throws: AssistantCLITextAssistantError.executableNotFound(.codex)) {
              _ = try await router.answer(question: "oi", in: conversation)
          }
      }

      @Test("a descoberta em cache é varrida uma vez em dez perguntas")
      @available(macOS 26.0, *)
      func discoveryCacheIsUsedOncePerWindow() async throws {
          let suite = "okamiuni.assistant-router-cache.\(UUID().uuidString)"
          let defaults = try #require(UserDefaults(suiteName: suite))
          defaults.removePersistentDomain(forName: suite)
          defer { defaults.removePersistentDomain(forName: suite) }

          let settingsStore = AssistantSettingsStore(defaults: defaults, key: "assistant")
          try settingsStore.save(.init(provider: .cli, cli: .init(kind: .codex)))
          let scans = Counter()
          let cache = CachedAssistantCLIDiscovery(
              discovery: AssistantCLIDiscovery(
                  environment: ["PATH": "/usr/bin"],
                  homeDirectory: "/tmp/casa",
                  bundleResourceDirectory: nil,
                  isExecutable: { path in scans.bump(); return path.hasSuffix("/codex") }
              ),
              validity: 60,
              now: { Date(timeIntervalSince1970: 0) }
          )
          let router = AssistantRouter(
              settingsStore: settingsStore,
              credentialStore: InMemoryAssistantCredentialStore(),
              cliInstallationProvider: { cache.installations() },
              cliExecutor: RecordingAssistantCLIExecutor(output: .codex)
          )
          for _ in 0..<10 { _ = try await router.answer(question: "oi", in: conversation) }
          let afterTen = scans.value
          for _ in 0..<10 { _ = try await router.answer(question: "oi", in: conversation) }
          #expect(scans.value == afterTen)
      }
      ```
      `RecordingAssistantCLIExecutor` guarda o último `AssistantCLIProcessRequest` e devolve uma saída válida no formato de cada CLI (`AssistantCLIResponseFormat`, `AssistantCLITextAssistant.swift:559-583`); `AlwaysAuthorizedProviderOAuth` implementa `AssistantProviderOAuthTokenProviding` devolvendo `true`/`"token"`; `Counter` é o mesmo da Task 11. Ponha os três em `Packages/UNISync/Tests/UNISyncTests/Fixtures/`, ao lado dos auxiliares que já existem lá.

- [ ] Cobrir `.providerOAuth` xAI com timeout chegando ao adaptador:
      ```swift
      @Test("xAI recebe o tempo generoso, não os 30 s antigos")
      @available(macOS 26.0, *)
      func providerOAuthUsesGenerousTimeout() async throws {
          let suite = "okamiuni.assistant-router-xai.\(UUID().uuidString)"
          let defaults = try #require(UserDefaults(suiteName: suite))
          defaults.removePersistentDomain(forName: suite)
          defer { defaults.removePersistentDomain(forName: suite) }

          let settingsStore = AssistantSettingsStore(defaults: defaults, key: "assistant")
          try settingsStore.save(.init(
              provider: .providerOAuth,
              providerOAuth: .init(kind: .xAI, model: "grok-4.6")
          ))
          let session = StubURLProtocol.session(routes: [
              "/v1/responses": [.json("{\"output_text\":\"pronto\"}")],
          ])
          let router = AssistantRouter(
              settingsStore: settingsStore,
              credentialStore: InMemoryAssistantCredentialStore(),
              session: session,
              providerOAuthTokenProvider: AlwaysAuthorizedProviderOAuth()
          )
          #expect(try await router.answer(question: "oi", in: conversation) == "pronto")
          let request = try #require(StubURLProtocol.requests(for: session).last)
          #expect(request.timeoutInterval >= 120)
      }
      ```
      Confira em `Packages/UNISync/Tests/UNISyncTests/Fixtures/` a forma exata de `StubURLProtocol.session(routes:)` e `StubURLProtocol.requests(for:)` — os testes atuais do roteador já as usam (`AssistantRouterTests.swift:20-24, 41-46`) — e o caminho real de `AssistantProviderOAuthClient.xAIResponsesURL` para montar a rota.

- [ ] Rodar e ver passar:
      ```bash
      swift test --package-path Packages/UNISync
      ```

- [ ] Commit:
      ```bash
      git add -A && git commit -m "test: golden do prompt de workspace e cobertura de CLI e OAuth no router

Acrescentar campo ao contexto do ambiente agora quebra um teste. As três
rotas que ninguém cobria (claude, codex, opencode) e a assinatura xAI
entram, com o tempo de 120 s aferido no adaptador. Spec 1.9.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
      ```

---

### Task 16: Registro das decisões e a cópia do README (spec 1.10)

O README ainda promete "sem mandar conteúdo para servidor algum" — verdade em 2026-08, mentira desde que o provedor virou configurável.

**Files**
- Modify `docs/decisoes-de-engenharia.md` (acrescentar ao fim, antes de nada apagar)
- Modify `README.md` (linha do Marco 5 no TL;DR: "✨ **Inteligência no dispositivo**: … sem mandar conteúdo para servidor algum."; tabela do Marco 5: "✨ **Análise local**"; "💬 **Perguntas contextuais**": "A resposta usa apenas o contexto local")

**Steps**

- [ ] Escrever as cinco entradas em `docs/decisoes-de-engenharia.md`:
      ```markdown
      ## Timeout de 30 s era errado para prompt de 400 mil caracteres (2026-09-01, SP1)

      O roteador nasceu com 30 s para API/LiteLLM (`AssistantRouter`), 60 s para CLI e
      120 s só para OAuth direto. Enquanto o orçamento do prompt era o da Foundation
      Models (8 mil caracteres), 30 s bastava. Quando o email inteiro passou a ir
      (400 mil), a mesma pergunta virou uma geração de minutos — e o dono viu o Grok
      morrer por tempo, não por erro.

      Duas coisas foram medidas no caminho:

      1. `URLRequest.timeoutInterval` **não** é o tempo da chamada. Ele é o tempo máximo
         entre pacotes. Uma resposta longa que chega devagar passa dele sem estourar, e
         uma geração que demora a começar estoura mesmo com a rede boa. O que fecha a
         conta é `URLSessionConfiguration.timeoutIntervalForResource`, e ele não estava
         configurado em lugar nenhum.
      2. O tempo do CLI tem piso, não só teto: um `codex` frio demora a subir. A faixa é
         30–300 s, e o padrão 120 s.

      ## Sem fallback silencioso de provedor (2026-09-01, SP1)

      A tentação era óbvia: falhou no Grok, resume no Mac. É exatamente o que não pode
      acontecer. A pessoa escolheu um provedor por uma razão — custo, qualidade, ou
      justamente privacidade — e um fallback automático toma essa decisão por ela, em
      silêncio, no pior momento possível.

      A fila de análise automática **pausa** depois de três falhas de ambiente (auth,
      rede, CLI ausente), grava o motivo em `analysis_queue_state` e mostra "Análise
      pausada · Tentar de novo" na lateral. Três, e não uma: uma falha é ruído de rede.

      A tabela é própria, e não `sync_state`, pelo mesmo motivo de `created_agenda_item`
      na v5: `sync_state.accountID` tem `REFERENCES account(id)` e as chaves estrangeiras
      estão ligadas — sem conta conectada não haveria onde gravar. E a fila é global.

      ## Codex por assinatura roda pelo CLI (2026-09-01, SP1)

      A assinatura ChatGPT não vira crédito de API. O caminho que funciona é o runtime
      oficial do Codex já instalado neste Mac: o OkamiUNI executa o binário num processo
      isolado e a sessão continua sendo do CLI — nenhum token do ChatGPT passa pelo app,
      nem é lido, nem é serializado.

      Consequência prática: `AssistantAvailability` para `.providerOAuth` com `kind ==
      .codex` precisa checar **duas** coisas — sessão presente **e** binário encontrado.
      Faltando o binário, o estado é `needsSetup`, não `needsSignIn`; mandar a pessoa
      fazer login de novo não resolveria nada.

      ## Dado não confiável vai entre delimitadores escapados (2026-09-01, SP1)

      Todo email, conta, caixa, agenda e turno de histórico entra no prompt dentro de
      `<untrusted-app-context>` / `<untrusted-assistant-history>`, com `<` e `>`
      escapados por `AssistantPrompt.escapedData`. Só esses dois caracteres: `&` é dado
      comum em assunto e link, e escapá-lo fazia o rascunho voltar com `&amp;` literal
      no corpo do email.

      A instrução personalizada da pessoa tem camada própria
      (`<user-configured-assistant-instructions>`), abaixo da política fixa e
      explicitamente marcada como preferência secundária: ela ajusta forma e
      especialidade, e não revoga nenhuma regra de segurança.

      O golden `Tests/Golden/workspace-prompt.txt` existe para que acrescentar um campo
      ao contexto do ambiente seja uma decisão, e não um efeito colateral.

      ## Opt-in para análise remota, e fila que pausa em vez de cair para o Mac (2026-09-01, SP1)

      A análise por mensagem é a única coisa do app que roda **sem** a pessoa pedir. Ligar
      o provedor interativo nela seria mandar cada mensagem recebida para um servidor por
      causa de uma escolha que a pessoa fez para outra finalidade.

      `AssistantSettings.automaticAnalysis` (schema v5) nasce `.onDeviceOnly` e a migração
      de v4 a preenche assim — inclusive para quem já tinha Grok ou LiteLLM configurado. O
      toggle só aparece para destino remoto, e vem com a frase que descreve a consequência
      exata: "Cada mensagem recebida sai deste Mac para {label}."
      ```

- [ ] Corrigir o README. Três trocas:
      - TL;DR, item do Marco 5:
        > ✨ **Inteligência com destino honesto**: o Foundation Models resume e identifica compromissos, responde perguntas sobre o email/conversa aberta e atua no composer (resumir, reescrever, encurtar, ajustar tom, corrigir e criar resposta) — e, quando você escolhe Grok, LiteLLM, Codex ou um CLI, o app **diz para onde o conteúdo vai**, em cada superfície, antes de mandar.
      - Tabela do Marco 5, linha "✨ **Análise local**": acrescentar ao fim "A análise automática continua no Mac por padrão; usar o provedor configurado nela é opt-in explícito, com a consequência escrita no toggle."
      - Tabela do Marco 5, linha "💬 **Perguntas contextuais**": trocar "A resposta usa apenas o contexto local" por "A resposta usa apenas o contexto do app e diz quando a informação não está nele; o rodapé mostra o destino (`Neste Mac`, `Grok · xAI`, `LiteLLM · host`…)".

- [ ] Conferir que nenhuma promessa incondicional sobrou:
      ```bash
      git grep -n -i 'sem mandar conteúdo para servidor algum\|apenas o contexto local\|nada sai deste Mac' -- README.md docs
      ```
      Esperado: só a linha de `AssistantDestination` no plano/decisões, nunca uma promessa do README.

- [ ] Rodar a suíte inteira e o app:
      ```bash
      for p in UNICore UNIDesign UNIShell UNISync; do (cd "Packages/$p" && swift test) || echo "FALHOU: $p"; done
      xcodegen generate && xcodebuild -project OkamiUNI.xcodeproj -scheme OkamiUNI -configuration Debug build 2>&1 | grep -E "error:|BUILD"
      ```
      Esperado: quatro suítes verdes e `** BUILD SUCCEEDED **`.

- [ ] Commit:
      ```bash
      git add -A && git commit -m "docs: registro do sub-projeto 1 e README sem promessa incondicional

Cinco entradas em decisoes-de-engenharia.md e a cópia do README passa a
depender do provedor escolhido. Spec 1.10.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
      ```

---

## Nota de ambiente: a suíte de UNIShell precisa de sessão gráfica

`Packages/UNIShell/Tests/UNIShellTests/RenderHarness.swift` hospeda SwiftUI numa `NSWindow`
posicionada a −50 000 pt e nunca trazida à frente: `Render.snapshot` grava o bitmap e
`CliqueDeEnsaio` (`:198-223`) injeta um evento de mouse dentro do processo.

Medido nesta máquina em 2026-09-01, e vale para quem executar este plano:

- **Fora do sandbox** a suíte roda normal — `swift test --package-path Packages/UNIShell
  --filter DashboardScreenTests` fecha em **3,5 s**, `✔ Test run with 4 tests in 1 suite passed`,
  e `--filter HairlineThicknessTests` em 1,7 s.
- **Dentro de um shell sandboxed** (sem acesso ao servidor de janelas), os conjuntos que
  sintetizam clique travam indefinidamente: `-[NSWindow _handleMouseDownEvent:]` fica parado em
  `__CFRunLoopServiceMachPort`. Travamento, não falha — nenhuma linha de relatório sai.

Portanto: rode a suíte de UNIShell numa sessão gráfica de verdade. Se você for um agente com shell
sandboxed, desative o sandbox para esta suíte ou peça ao dono do projeto para rodá-la; e não
confunda o travamento com defeito do código que você acabou de escrever. É o mesmo terreno da
decisão já registrada, "`NSApp.postEvent` mata um processo de teste em silêncio".

---

## Auto-revisão

### Cobertura da spec, item por item

| Item da spec | Onde |
|---|---|
| 1.1 Renomes (tabela) | Task 1 (contrato de texto) e Task 2 (análise, ponte, painel, prompt) |
| 1.2 `AssistantDestination` + cópia | Task 3 (o valor) e Task 13 (adoção em painel, dashboard, popover, Ajustes) |
| 1.3 `AssistantConversation` unificada | Task 8 (máquina, `ask/draftReply/summarize/briefing/cancel/clear/retry`, `kind: .draft`, histórico 16, `emptyResponse`) e Task 9 (as superfícies; `run/runDraft/runSuggestion` removidos) |
| 1.4 Budget, timeouts, idioma | Task 4 (`maximumTextCharacters`, `maximumWorkspaceEmails`, `maximumWorkspaceAgendaItems`, `maximumCustomInstructionCharacters`, 120 s, `timeoutIntervalForResource`) e Task 5 (idioma sempre emitido) |
| 1.5 `AssistantAvailability`, `didChange`, `IntelligencePresentation`, `AssistantFailure` | Task 10 (disponibilidade, `addDidChangeHandler`, `AppComposition.assistantAvailability`, `needsSetup`/`needsSignIn`, botão com motivo e "Abrir Ajustes") e Task 6 (`AssistantFailure` + `AssistantFailureBand`) |
| 1.6 Coordenadores, cache de CLI, stderr | Task 12 (atores + estado observável) e Task 11 (`CachedAssistantCLIDiscovery` 60 s + `invalidate()`, stderr 4 KiB, comentário datado das flags) |
| 1.7 `AssistantMarkdown` | Task 7 |
| 1.8 `automaticAnalysis` opt-in | Task 14 (schema v5, `RoutedMessageAnalyzer`, `TextAssistantMessageAnalyzer`, pausa após 3 falhas, faixa na lateral, toggle em Ajustes) |
| 1.9 Testes | Distribuídos: `AssistantRouterTests` `.cli`/`.providerOAuth`/timeout/cache → Task 15; `AssistantPromptTests` (100 mil caracteres, 100 emails, golden) → Tasks 4 e 15; `AssistantConversationTests` → Task 8; `DashboardScreenTests` "Gerar rascunho" → Task 9; `AssistantAvailabilityTests` → Task 10; `AssistantFailureTests` → Task 6; `RoutedMessageAnalyzerTests` e `MessageIntelligenceCoordinatorTests` → Task 14; `AssistantBehaviorPreferencesTests` → Task 5 |
| 1.10 Registro | Task 16 |

Nenhum item de 1.1 a 1.10 ficou sem tarefa.

### O que a seção 1 deixa pronto para as seções 2–4 (planejadas depois, não aqui)

- `AssistantConversation.briefing()` e `briefingText` existem e são testados (§2.5).
- `AssistantConversation.briefingQuestion` já é o texto fixo da §2.5.
- `AssistantMarkdown` é público dentro do pacote, pronto para a faixa de briefing da §2.2.
- `AssistantDestination.label` já é o rótulo que o cabeçalho do dashboard vai mostrar (§2.2).
- `MessageAnalysisResult` mantém a forma que a §3.1 vai estender com `triage`.
- `DashboardFocus` **não** muda de contrato nesta seção, como a §2.3 exige.

### Três desvios da spec, todos deliberados e registrados no corpo do plano

1. **`AssistantConversation.briefing` propriedade + `briefing()` método** — impossível em Swift (`invalid redeclaration`, conferido com `swiftc`). A propriedade chama-se `briefingText`. (Task 8)
2. **`AssistantRouter.availability()` "vira" `AssistantAvailability`** — impossível sem quebrar o requisito de `TextAssisting`, que vive em UNICore e não enxerga `AssistantDestination`. O método rico é `assistantAvailability()`; o do protocolo passa a ser derivado dele. (Task 10)
3. **Pausa da fila em `sync_state`** — a tabela tem `accountID REFERENCES account(id)` e a fila é global; sem conta conectada não haveria onde gravar. A migração `v15` cria `analysis_queue_state`, de linha única. (Task 14)

### Varredura de marcadores

Nenhum "TBD", "similar à Task N", "adicione tratamento de erro" ou "escreva testes" no corpo das
tarefas: todo passo de código traz o código, e o código repetido entre tarefas foi repetido de
propósito, porque o executor lê uma tarefa isolada.

Quatro pontos pedem **conferência no código antes de escrever**, e estão marcados como tal dentro
das tarefas (não são placeholders — são as fronteiras onde uma assinatura existente manda):
a forma exata de `ChromeButton` (Task 6), a de `DetectedEvent.init` e `MailCategory` (Task 14),
a de `StubURLProtocol` e o nome do stub de executor de CLI (Task 15), e o nome atual dos
auxiliares de teste em `Packages/UNISync/Tests/UNISyncTests/Fixtures/` (Tasks 11 e 15).

### Consistência de nomes entre tarefas

`TextAssisting`, `AssistantMailContext`, `AssistantEmailContext`, `AssistantWorkspaceContext`,
`AssistantWorkspaceEmailContext`, `AssistantConversationSnapshot`, `AssistantTurn`,
`AssistantTurnRole`, `WritingAction`, `TextAssistantError`, `MessageAnalyzing`,
`MessageAnalysisInput`, `MessageAnalysisResult`, `MessageAnalysisError`,
`AppleIntelligenceAvailability`, `AssistantPrompt`, `AssistantBridge`, `AssistantPanel`,
`AssistantConversation`, `AssistantScope`, `AssistantSuggestion`, `AssistantContext`,
`AssistantMessage`, `AssistantSpeaker`, `AssistantRequest`, `AssistantTurnKind`,
`AssistantEngine`, `AssistantDestination`, `AssistantAvailability`,
`AssistantAvailabilityModel`, `AssistantFailure`, `AssistantFailureBand`, `AssistantMarkdown`,
`AssistantMarkdownBlock`, `AutomaticAnalysisRoute`, `RoutedMessageAnalyzer`,
`TextAssistantMessageAnalyzer`, `CachedAssistantCLIDiscovery`, `AnalysisQueueState`,
`AnalysisQueueStateStore` — usados com a mesma grafia em todas as tarefas que os citam.
`FoundationModelsTextAssistant`, `FoundationModelsMessageAnalyzer` e
`FoundationModelsTextAssistantValidation` **mantêm** o nome, como a spec manda.
