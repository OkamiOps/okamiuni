# Sub-project 1 — Assistant core: implementation plan

[Português (Brasil)](2026-09-01-sp1-nucleo-do-assistente.md) · **English**

> Historical implementation plan from September 1, 2026. Instructions, test counts and code examples describe that stage of the project. The separate remote-AI opt-in below was superseded in v0.5.3; see the [v0.5.4 README](../../../README.md) for current behavior. Original identifiers, commands and source literals are preserved.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the OkamiUNI assistant tell the truth about the provider, have a single state machine and a single prompt budget, and never send content off the Mac without the person choosing that.

**Architecture:** The pure contract (`TextAssisting`, `AssistantMailContext`, `AssistantPrompt`) lives in UNICore/UNISync without a misleading prefix; `AssistantRouter` remains the single gateway that chooses an adapter per call and will publish cheap, network-free `AssistantDestination` and `AssistantAvailability`. In the shell, `AssistantConversation` (`@MainActor @Observable`) becomes the sole owner of the transcript, `isLoading`, `failure`, and `task`, injected into the panel, dashboard, message window, and reader popover; errors from any adapter pass through one translator (`AssistantFailure`) and one band (`AssistantFailureBand`).

**Tech Stack:** Swift 6 strict concurrency, SwiftUI, Swift Testing, GRDB (v15 migration of the analysis queue), FoundationModels

**Spec:** docs/superpowers/specs/2026-09-01-ia-e-dashboard-design.md (sections 0 and 1)

---

## Global Constraints

- **Swift Testing, never XCTest.** `import Testing`, `@Suite`, `@Test`, `#expect`, `#require`.
- **A new test starts red.** Each task writes the test, runs it, sees it fail with the expected message, and only then implements. A test that passes with broken code is a defect (`README.md` → "How this project is tested").
- **No transitional typealiases during renames.** Table 1.1 is applied at once, across all packages and tests; there is no `typealias OnDeviceTextAssisting = TextAssisting`.
- **No literal color, radius, or shadow in a new view.** Use only `Theme` tokens (`theme.surface2`, `theme.line2`, `theme.radiusSmall`, `Hairline.thickness(displayScale)`); no `Color.black.opacity(...)` or `cornerRadius: 20`.
- **120-second timeouts.** `AssistantRouter.requestTimeout` defaults to 120; `cliRequestTimeout` defaults to 120 with a 30–300 range; `.providerOAuth` keeps `max(requestTimeout, 120)`; adapters' `URLSessionConfiguration` receives `timeoutIntervalForResource` in addition to `timeoutIntervalForRequest`.
- **`maximumCustomInstructionCharacters = 6_000`** limits `customInstruction` (today it is truncated to 1,200 by `maximumHistoryTurnCharacters`).
- **`automaticAnalysis` starts as `.onDeviceOnly`.** The remote route is explicit opt-in; the queue **pauses** instead of silently falling back to the Mac.
- **The "local" copy disappears.** No sentence may claim local processing without consulting `AssistantDestination`. "Nada sai deste Mac." appears only for `.foundationModels`.
- **Keep pure logic outside views.** A SwiftUI `View` is implicitly `@MainActor`; `static` logic inside it traps at runtime when a nonisolated test calls it (`docs/decisoes-de-engenharia.md`).
- **Hairline is `1/displayScale`**, and a border is `strokeBorder`.
- **Frequent commits**, at least one per task, ending with:
  ```
  Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
  ```
- **Each task ends compiling with the touched package's tests green.** "Green" means no new failure. The baseline measured on 2026-09-01 on `main` (0a6330a) already has 4 failures unrelated to this work and they must not be "fixed" in passing: `DatabaseMailSourceTests.swift:57` ("O corpo vem junto para quem já o tem no banco"), `DatabaseBodyFetcherTests.swift:180`, `GmailMirrorTests.swift:110` ("Arquivar tira a INBOX") in UNISync, and in UNIShell, `QuickReplyBandTests.swift:817`, `TrashTests.swift:102` ("só a Lixeira e Enviadas têm símbolo"), `ReaderHTMLLoadingTests.swift:62` and `:90`, and `InboxAssistantIntegrationTests.swift:450` and `:516` (measured on 2026-09-02 in a clean checkout of 3d9af34: 9 inherited failures in total, all pixel/harness or Gmail/body failures, none AI-related). If a task makes any of them pass or changes its message, record it in the commit.
- **The full UNIShell suite ran in the orchestrator shell on 2026-09-01** (≈135 s, sandboxed). If it hangs in your environment, see the environment note at the end of the plan before suspecting the code.

---

## Test commands verified on this machine (2026-09-01)

All four packages are pure SwiftPM. **There is no test scheme in Xcode** — `project.yml` only builds the app target.

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

Actually verified on this machine on 2026-09-01:

- `swift test --package-path Packages/UNICore --filter DashboardFocusTests` → `✔ Test run with 11 tests in 1 suite passed`, 16 s (first run, with compilation).
- `swift test --package-path Packages/UNISync --filter AssistantRouterTests` → `✔ Test run with 4 tests in 1 suite passed`, 5.8 s (incremental).
- `swift test --package-path Packages/UNIShell --filter DashboardScreenTests` → `✔ Test run with 4 tests in 1 suite passed`, 3.5 s. **Only outside a sandboxed shell** — see the environment note at the end of this plan.

The first compilation of `Packages/UNIShell` takes more than 2 min; run it in the background for the long loop.

The app target has no tests; it is only the wiring. After changing `App/`, compile:

```bash
test -f Config/Google.xcconfig || cp Config/Google.example.xcconfig Config/Google.xcconfig
xcodegen generate
xcodebuild -project OkamiUNI.xcodeproj -scheme OkamiUNI -configuration Debug build 2>&1 | grep -E "error:|BUILD"
```

Never run `Tools/rodar.sh` for verification: it **opens the app**. Interface verification uses the offscreen harness (`Packages/UNIShell/Tests/UNIShellTests/RenderHarness.swift`, `Render.snapshot`).

---

## File structure

### Renamed (`git mv`, no typealias)

| From | To | Responsibility |
|---|---|---|
| `Packages/UNICore/Sources/UNICore/OnDeviceTextAssistant.swift` | `.../TextAssistant.swift` | Pure text-assistant contract: contexts, turns, writing actions, errors |
| `Packages/UNICore/Sources/UNICore/OnDeviceAssistantMailContext+Message.swift` | `.../AssistantMailContext+Message.swift` | Translates the app model to the factual boundary |
| `Packages/UNICore/Sources/UNICore/OnDeviceMessageAnalysis.swift` | `.../MessageAnalysis.swift` | Pure contract for per-message persisted analysis |
| `Packages/UNICore/Tests/UNICoreTests/OnDeviceTextAssistantTests.swift` | `.../TextAssistantTests.swift` | Contract tests |
| `Packages/UNICore/Tests/UNICoreTests/OnDeviceAssistantMailContextTests.swift` | `.../AssistantMailContextTests.swift` | Translation tests |
| `Packages/UNICore/Tests/UNICoreTests/OnDeviceMessageAnalysisTests.swift` | `.../MessageAnalysisTests.swift` | Analysis-contract tests |
| `Packages/UNIShell/Sources/UNIShell/Support/OnDeviceAssistantBridge.swift` | `.../Support/AssistantBridge.swift` | Connects shell surfaces to `TextAssisting` |
| `Packages/UNIShell/Tests/UNIShellTests/OnDeviceAssistantBridgeTests.swift` | `.../AssistantBridgeTests.swift` | Bridge tests |
| `Packages/UNIShell/Sources/UNIShell/Inbox/LocalAssistantPanel.swift` | `.../Inbox/AssistantPanel.swift` | The panel view (the state machine leaves here in Task 6) |
| `Packages/UNIShell/Tests/UNIShellTests/LocalAssistantPanelTests.swift` | `.../AssistantPanelTests.swift` | Panel tests |
| `Packages/UNISync/Tests/UNISyncTests/FoundationModelsTextAssistantTests.swift` | `.../AssistantPromptTests.swift` | Prompt tests shared by the four adapters |

### Created

| File | Responsibility |
|---|---|
| `Packages/UNISync/Sources/UNISync/AssistantDestination.swift` | `AssistantDestination` — `label`/`detail`/`isLocal` derived from `AssistantSettings` |
| `Packages/UNISync/Sources/UNISync/AssistantAvailability.swift` | Observable `AssistantAvailability` + `AssistantAvailabilityModel` |
| `Packages/UNISync/Sources/UNISync/AssistantURLSessionFactory.swift` | Derives a `URLSession` with `timeoutIntervalForRequest` **and** `ForResource` |
| `Packages/UNISync/Sources/UNISync/CachedAssistantCLIDiscovery.swift` | 60-second cache of CLI scanning, with `invalidate()` |
| `Packages/UNISync/Sources/UNISync/RoutedMessageAnalyzer.swift` | Chooses the analysis engine per call, according to `automaticAnalysis` |
| `Packages/UNISync/Sources/UNISync/TextAssistantMessageAnalyzer.swift` | Strict JSON analysis through the configured provider |
| `Packages/UNISync/Sources/UNISync/Database/AnalysisQueueState.swift` | Persisted `running`/`paused(reason)` state of the analysis queue |
| `Packages/UNIShell/Sources/UNIShell/Inbox/AssistantConversation.swift` | The sole state machine: transcript, `isLoading`, `failure`, `task`, `briefing` |
| `Packages/UNIShell/Sources/UNIShell/Support/AssistantMarkdown.swift` | `AssistantMarkdown` + `AssistantMarkdownBlock`, moved out of the popover |
| `Packages/UNIShell/Sources/UNIShell/Support/AssistantFailure.swift` | `AssistantFailure`, `AssistantFailure.Recovery`, and `AssistantFailureBand` |
| `Packages/UNISync/Tests/UNISyncTests/AssistantDestinationTests.swift` | One case per provider in table 1.2 |
| `Packages/UNISync/Tests/UNISyncTests/AssistantAvailabilityTests.swift` | Each provider in each credential state |
| `Packages/UNISync/Tests/UNISyncTests/CachedAssistantCLIDiscoveryTests.swift` | 60-second validity and `invalidate()` |
| `Packages/UNISync/Tests/UNISyncTests/RoutedMessageAnalyzerTests.swift` | Routing by configuration and strict JSON |
| `Packages/UNISync/Tests/UNISyncTests/Golden/workspace-prompt.txt` | Workspace prompt golden |
| `Packages/UNIShell/Tests/UNIShellTests/AssistantConversationTests.swift` | `draftReply`, `cancel`, history 16, `emptyResponse`, `briefing` |
| `Packages/UNIShell/Tests/UNIShellTests/AssistantFailureTests.swift` | Each adapter enum → message and recovery |
| `Packages/UNIShell/Tests/UNIShellTests/AssistantMarkdownTests.swift` | Blocks and `.draft` turn without Markdown |

### Modified (file → what changes)

| File | Change |
|---|---|
| `Packages/UNISync/Sources/UNISync/FoundationModelsTextAssistant.swift` | `FoundationModelsTextAssistantPrompt` → `AssistantPrompt`; `Budget` gains `maximumTextCharacters`, `maximumWorkspaceEmails`, `maximumWorkspaceAgendaItems`; `transform` and `render(_:budget:)` start respecting them; language leaves the fixed prompt |
| `Packages/UNISync/Sources/UNISync/AssistantSettings.swift` | `generatedInstructions()` always emits language; `automaticAnalysis`; `currentSchemaVersion = 5` |
| `Packages/UNISync/Sources/UNISync/AssistantSettingsStore.swift` | `addDidChangeHandler(_:)` publishes every `save`/`reset` |
| `Packages/UNISync/Sources/UNISync/AssistantRouter.swift` | Timeouts 120; session with `timeoutIntervalForResource`; cached CLI discovery; `assistantAvailability()`; `destination()` |
| `Packages/UNISync/Sources/UNISync/AssistantCLITextAssistant.swift` | `processFailed(exitCode:stderrTail:)`; captured stderr (4 KiB, tail); timeout range 30–300 |
| `Packages/UNISync/Sources/UNISync/LiteLLMOAuthCoordinator.swift` | Becomes an `actor` + observable `LiteLLMOAuthSessionState` |
| `Packages/UNISync/Sources/UNISync/AssistantProviderOAuthCoordinator.swift` | Becomes an `actor` + observable `AssistantProviderOAuthSessionState` |
| `Packages/UNISync/Sources/UNISync/MessageIntelligenceCoordinator.swift` | Pauses the queue after 3 auth/network failures, with persisted state |
| `Packages/UNISync/Sources/UNISync/Database/SyncDatabase.swift` | `v15` migration: analysis-queue state table |
| `Packages/UNISync/Sources/UNISync/AppComposition.swift` | `RoutedMessageAnalyzer`, `assistantAvailability`, cached discovery |
| `Packages/UNIShell/Sources/UNIShell/Inbox/FolderSidebar.swift` | `IntelligencePresentation` with `needsSetup`/`needsSignIn`, without `.configuredAssistant` |
| `Packages/UNIShell/Sources/UNIShell/Inbox/DashboardScreen.swift` | Consumes `AssistantConversation`; `run/runDraft/runSuggestion` removed |
| `Packages/UNIShell/Sources/UNIShell/Inbox/InboxScreen.swift` | Owns `AssistantConversation`; passes `AssistantDestination` |
| `Packages/UNIShell/Sources/UNIShell/Inbox/ReaderIntelligencePopover.swift` | Uses `AssistantMarkdown` and `AssistantConversation` |
| `Packages/UNIShell/Sources/UNIShell/Windows/MessageWindow.swift` | Receives `AssistantConversation` by injection |
| `Packages/UNIShell/Sources/UNIShell/Windows/SettingsSections.swift` | Coordinator state; automatic-analysis toggle; conditional copy |
| `App/OkamiUNIApp.swift` | `IntelligencePresentation` from `assistantAvailability`, without fixed `.configuredAssistant` |
| `README.md` | "sem mandar conteúdo para servidor algum" becomes provider-dependent |
| `docs/decisoes-de-engenharia.md` | Five new entries (§1.10) |

---

### Task 1: Text-contract renames (table 1.1, group A)

The protocol lives in UNICore, is implemented in UNISync, and is consumed in UNIShell and `App/`. Renaming it in only one package does not compile: this task is atomic across all four.

**Files**
- Rename `Packages/UNICore/Sources/UNICore/OnDeviceTextAssistant.swift` → `Packages/UNICore/Sources/UNICore/TextAssistant.swift` (via `git mv`)
- Rename `Packages/UNICore/Sources/UNICore/OnDeviceAssistantMailContext+Message.swift` → `Packages/UNICore/Sources/UNICore/AssistantMailContext+Message.swift` (via `git mv`)
- Rename `Packages/UNICore/Tests/UNICoreTests/OnDeviceTextAssistantTests.swift` → `.../TextAssistantTests.swift` (via `git mv`)
- Rename `Packages/UNICore/Tests/UNICoreTests/OnDeviceAssistantMailContextTests.swift` → `.../AssistantMailContextTests.swift` (via `git mv`)
- Modify: any versioned `.swift` file that cites the old names (25 files today; `git grep -l` in step 1 gives the exact list)

**Interfaces**
- Consumes: nothing new.
- Produces (UNICore, public):
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
The contexts carrying the same misleading prefix go along with it (a coherent extension of table 1.1, which only names the umbrella): `AssistantEmailContext`, `AssistantMailboxContext`, `AssistantAgendaContext`, `AssistantWorkspaceEmailContext`, `AssistantPendingContext`, `AssistantWorkspaceContext`.

**Steps**

- [ ] Record the target before changing anything: run
      ```bash
      git grep -c -E 'OnDeviceTextAssisting|OnDeviceAssistantMailContext|OnDeviceAssistantConversation|OnDeviceAssistantTurn|OnDeviceWritingAction|OnDeviceTextAssistantError|OnDeviceAssistant(Email|Mailbox|Agenda|WorkspaceEmail|Workspace|Pending)Context' -- '*.swift' | sort -t: -k2 -rn
      ```
      and save the output in the commit body. It proves that nothing was left behind.

- [ ] Write the failing test. In `Packages/UNICore/Tests/UNICoreTests/AssistantNamingTests.swift` (new file):
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

- [ ] Run it and see it fail:
      ```bash
      swift test --package-path Packages/UNICore --filter AssistantNamingTests
      ```
      Expected: compilation error `cannot find 'AssistantTurn' in scope` (and the same for `AssistantConversationSnapshot`, `AssistantEmailContext`, `WritingAction`, `TextAssistantError`, `TextAssisting`). A compilation failure **is** the expected failure here: the rename is the defect.

- [ ] Rename the files:
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

- [ ] Apply the names from longest to shortest (the order prevents one prefix from consuming another):
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

- [ ] Adjust by hand what `perl` cannot reach: comments that say "assistente local" where the type is now neutral. In `Packages/UNICore/Sources/UNICore/TextAssistant.swift`, the `AssistantEmailContext` doc comment (line 3 of the file) changes from "contexto factual para o assistente local" to "contexto factual para o assistente"; the `TextAssisting` comment ("A porta assíncrona…") loses the word "local"; `TextAssistantError.errorDescription` changes "O assistente local" to "O assistente" in the four cases that mention it:
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

- [ ] Run it and see it pass, package by package:
      ```bash
      swift test --package-path Packages/UNICore
      swift test --package-path Packages/UNISync
      swift test --package-path Packages/UNIShell
      ```
      Expected: three `✔ Test run with N tests ... passed` lines, with no `OnDevice…` not-found warning.

- [ ] Compile the app (it is the consumer of `composition.textAssistant`):
      ```bash
      xcodegen generate && xcodebuild -project OkamiUNI.xcodeproj -scheme OkamiUNI -configuration Debug build 2>&1 | grep -E "error:|BUILD"
      ```
      Expected: `** BUILD SUCCEEDED **`.

- [ ] Commit:
      ```bash
      git add -A && git commit -m "refactor: TextAssisting e AssistantMailContext sem o prefixo OnDevice

O contrato atende Grok, LiteLLM, Codex e CLI; o nome dizia 'no
dispositivo' em todos eles. Tabela 1.1 da spec, grupo do texto.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
      ```

---

### Task 2: Renames of analysis, bridge, panel, and prompt (table 1.1, group B)

**Files**
- Rename `Packages/UNICore/Sources/UNICore/OnDeviceMessageAnalysis.swift` → `.../MessageAnalysis.swift`
- Rename `Packages/UNICore/Tests/UNICoreTests/OnDeviceMessageAnalysisTests.swift` → `.../MessageAnalysisTests.swift`
- Rename `Packages/UNIShell/Sources/UNIShell/Support/OnDeviceAssistantBridge.swift` → `.../Support/AssistantBridge.swift`
- Rename `Packages/UNIShell/Tests/UNIShellTests/OnDeviceAssistantBridgeTests.swift` → `.../AssistantBridgeTests.swift`
- Rename `Packages/UNIShell/Sources/UNIShell/Inbox/LocalAssistantPanel.swift` → `.../Inbox/AssistantPanel.swift`
- Rename `Packages/UNIShell/Tests/UNIShellTests/LocalAssistantPanelTests.swift` → `.../AssistantPanelTests.swift`
- Rename `Packages/UNISync/Tests/UNISyncTests/FoundationModelsTextAssistantTests.swift` → `.../AssistantPromptTests.swift`
- Modify: any versioned `.swift` file that cites the old names

**Interfaces**
- Produces (UNICore, public):
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
- Produces (UNISync, internal): `enum AssistantPrompt` (formerly `FoundationModelsTextAssistantPrompt`). `FoundationModelsTextAssistantValidation` **keeps its name** — spec §4.2 still cites it.
- Produces (UNIShell, public): `AssistantPanel`, `AssistantPanelDebugState`, `AssistantConversation`, `AssistantScope`, `AssistantSuggestion`, `AssistantContext`, `AssistantMessage`, `AssistantSpeaker`, `AssistantRequest`, `AssistantBridge`.

**Steps**

- [ ] Write the failing test. In `Packages/UNIShell/Tests/UNIShellTests/AssistantNamingTests.swift` (new file):
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

- [ ] Run it and see it fail:
      ```bash
      swift test --package-path Packages/UNIShell --filter AssistantShellNamingTests
      ```
      Expected: `cannot find 'AssistantScope' in scope`, `cannot find 'AssistantSuggestion' in scope`, `cannot find type 'AppleIntelligenceAvailability' in scope`.

- [ ] Rename the files:
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

- [ ] Apply the names from longest to shortest:
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

- [ ] Correct the `@Suite` names that `perl` does not touch because they are standalone literals. In `Packages/UNISync/Tests/UNISyncTests/AssistantPromptTests.swift`, change `@Suite("Assistente de texto local")` (or whatever label is there) to `@Suite("Prompt do assistente")`. In `Packages/UNIShell/Tests/UNIShellTests/AssistantPanelTests.swift`, the label becomes `@Suite("Painel do assistente")`.

- [ ] Run it and see it pass:
      ```bash
      swift test --package-path Packages/UNICore
      swift test --package-path Packages/UNISync
      swift test --package-path Packages/UNIShell
      xcodegen generate && xcodebuild -project OkamiUNI.xcodeproj -scheme OkamiUNI -configuration Debug build 2>&1 | grep -E "error:|BUILD"
      ```
      Expected: three green suites and `** BUILD SUCCEEDED **`.

- [ ] Commit:
      ```bash
      git add -A && git commit -m "refactor: análise, ponte, painel e prompt sem prefixo mentiroso

AppleIntelligenceAvailability passa a nomear só o que é do Foundation
Models; AssistantPrompt é dos quatro adaptadores. Tabela 1.1, grupo B.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
      ```

---

### Task 3: `AssistantDestination` (spec 1.2)

A single value answers "where does my email go when I press this?"

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

- [ ] Write the failing test. `Packages/UNISync/Tests/UNISyncTests/AssistantDestinationTests.swift`:
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

- [ ] Run it and see it fail:
      ```bash
      swift test --package-path Packages/UNISync --filter AssistantDestinationTests
      ```
      Expected: `cannot find 'AssistantDestination' in scope`.

- [ ] Implement. `Packages/UNISync/Sources/UNISync/AssistantDestination.swift`:
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

- [ ] Run it and see it pass:
      ```bash
      swift test --package-path Packages/UNISync --filter AssistantDestinationTests
      ```
      Expected: `✔ Test run with 5 tests in 1 suite passed`.

- [ ] Prove it by mutation: change `isLocal: true` to `isLocal: false` in the `.foundationModels` branch and confirm that `localDestination` fails; undo. Change `"LiteLLM"` to `"API"` and confirm that `openAICompatibleDestinations` fails; undo.

- [ ] Package suite and commit:
      ```bash
      swift test --package-path Packages/UNISync
      git add -A && git commit -m "feat: AssistantDestination diz para onde o email vai

Um valor só, derivado das preferências, com label, detail e isLocal.
Spec 1.2.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
      ```

---

### Task 4: Budget and timing through the prompt, router, and adapters (spec 1.4)

Today `AssistantPrompt.transform` truncates text at a fixed 8,000 characters (`FoundationModelsTextAssistant.swift:352`), and `render(_ workspace:)` (`:429`) ignores the budget and hard-codes 24 emails / 32 appointments. Commit `0a6330a` only passed `Budget` to the email context.

**Files**
- Modify `Packages/UNISync/Sources/UNISync/FoundationModelsTextAssistant.swift` (`Budget` at `:192-208`; `transform` at `:308-356`; `mailContext` at `:394-413`; `render(_ workspace:)` at `:429-506`; `actionDescription` at `:358-377`)
- Modify `Packages/UNISync/Sources/UNISync/AssistantRouter.swift` (`init` at `:34-57`, `providerOAuthAssistant` at `:250`)
- Modify `Packages/UNISync/Sources/UNISync/AssistantCLITextAssistant.swift` (`requestTimeout` at `:451-462`)
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

- [ ] Write the failing tests. Add to `Packages/UNISync/Tests/UNISyncTests/AssistantPromptTests.swift`:
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
      And in `Packages/UNISync/Tests/UNISyncTests/AssistantRouterTests.swift`:
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

- [ ] Run it and see it fail:
      ```bash
      swift test --package-path Packages/UNISync --filter 'AssistantPromptTests|AssistantRouterTests'
      ```
      Expected: `extra argument 'budget' in call` in `AssistantPrompt.render`, `cannot find 'AssistantURLSessionFactory' in scope`, and `AssistantPrompt.maximumCustomInstructionCharacters` does not exist.

- [ ] Expand `Budget`. In `FoundationModelsTextAssistant.swift`, replace the `struct Budget` block (lines 190–208) with:
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

- [ ] Make `transform` use the budget. In `AssistantPrompt.transform` (line 351 of the original file), replace
      ```swift
      \(bounded(text, maximumCharacters: maximumTextCharacters))
      ```
      with
      ```swift
      \(bounded(text, maximumCharacters: budget.maximumTextCharacters))
      ```
      and in `actionDescription`, pass the custom-instruction budget:
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

- [ ] Make the workspace snapshot use the budget. Change the private signature to internal and propagate it:
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
      `maximumWorkspaceEmails` and `maximumWorkspaceAgendaItems` stop being type constants (lines 176 and 178) and are deleted; anyone who needs the number reads it from `Budget`.

- [ ] Create the session factory. `Packages/UNISync/Sources/UNISync/AssistantURLSessionFactory.swift`:
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

- [ ] Change the router timings. In `AssistantRouter.swift`, in `init` (lines 34–57):
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

- [ ] Expand the CLI range. In `AssistantCLITextAssistant.swift`, `init` (line 457) now takes `requestTimeout: TimeInterval = 120`, and line 462 becomes:
      ```swift
      self.requestTimeout = min(max(requestTimeout, 30), 300)
      ```

- [ ] Run it and see it pass:
      ```bash
      swift test --package-path Packages/UNISync
      ```
      Expected: green suite. If `FoundationModelsTextAssistantTests` (now `AssistantPromptTests`) had an assertion pinning `maximumWorkspaceEmails` as a type constant, update it to `AssistantPrompt.Budget.onDevice.maximumWorkspaceEmails`.

- [ ] Prove it by mutation: change `budget.maximumTextCharacters` back to `maximumTextCharacters` in `transform` and confirm that `configuredTransformKeepsLongText` fails; undo. Change `budget.maximumWorkspaceEmails` back to `24` and confirm that `workspaceRespectsBudget` fails; undo.

- [ ] Commit:
      ```bash
      git add -A && git commit -m "fix: o orçamento atravessa transform e o retrato do ambiente

Timeout de 30 s era errado para prompt de 400 mil caracteres, e
render(workspace) ignorava o Budget cravando 24/32. Spec 1.4.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
      ```

---

### Task 5: The preferences' language always wins (spec 1.4)

`generatedInstructions()` emits the language line only when it is **not** pt-BR (`AssistantSettings.swift:418`), while the `answer` prompt opens with "Responda à pergunta atual em português do Brasil" (`FoundationModelsTextAssistant.swift:283`) — after the instruction layer. The preference never wins.

**Files**
- Modify `Packages/UNISync/Sources/UNISync/AssistantSettings.swift` (`generatedInstructions()` at `:414-424`)
- Modify `Packages/UNISync/Sources/UNISync/FoundationModelsTextAssistant.swift` (`answer` at `:277-306`; `transform` at `:308-330`)
- Create `Packages/UNISync/Tests/UNISyncTests/AssistantBehaviorPreferencesTests.swift`

**Interfaces**
- Produces: `AssistantBehaviorPreferences.generatedInstructions() -> String` now emits the language line in every case.

**Steps**

- [ ] Write the failing test. `Packages/UNISync/Tests/UNISyncTests/AssistantBehaviorPreferencesTests.swift`:
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

- [ ] Run it and see it fail:
      ```bash
      swift test --package-path Packages/UNISync --filter AssistantBehaviorPreferencesTests
      ```
      Expected: two failures — `portugueseIsEmittedToo` because the line is suppressed, and `englishNeverMentionsPortuguese` because `AssistantPrompt.answer` starts with "em português do Brasil".

- [ ] Always emit the language. In `AssistantSettings.swift`, inside `generatedInstructions()`, replace line 418
      ```swift
      if language != .portugueseBrazil { instructions.append(language.promptInstruction) }
      ```
      with
      ```swift
      // Sem condição: enquanto pt-BR era o silêncio, a preferência da pessoa
      // perdia para a linha fixa do prompt, que dizia português sempre.
      instructions.append(language.promptInstruction)
      ```

- [ ] Remove the language from the fixed prompt. In `AssistantPrompt.answer`, the opening (lines 283–284) becomes:
      ```swift
      Responda à pergunta atual com a profundidade que ela exigir. Comece pela
      resposta mais útil.
      ```
      And in `AssistantPrompt.transform`, the two `languageInstruction` values that hard-code pt-BR (lines 326 and 329) become:
      ```swift
      case .customInstruction:
          usesMailContext = true
          languageInstruction = "Execute a tarefa de escrita abaixo."
      default:
          usesMailContext = false
          languageInstruction = "Execute a tarefa de escrita abaixo."
      ```
      The `.draftReply` case **does not change**: replying in Portuguese to an English message is the defect that rule fixes, and it concerns the conversation's language, not the preference.

- [ ] Run it and see it pass:
      ```bash
      swift test --package-path Packages/UNISync
      ```
      Expected: green suite. Older tests that asserted the absence of the language line for pt-BR need to be inverted — the absence was the defect.

- [ ] Prove it by mutation: put back `if language != .portugueseBrazil` and confirm that `portugueseIsEmittedToo` fails; undo.

- [ ] Commit:
      ```bash
      git add -A && git commit -m "fix: a preferência de idioma vence o prompt fixo

A linha só era emitida fora de pt-BR e o prompt de answer abria em
português. Agora o idioma sai sempre das preferências. Spec 1.4.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
      ```

---

### Task 6: `AssistantFailure` and `AssistantFailureBand` (spec 1.5)

Four error enums were flattened into `localizedDescription`, with no recovery action (`LocalAssistantPanel.swift:267-274`, `DashboardScreen.swift:774-777`). One translation, one band. It comes **before** the state machine because the state machine stores `failure`.

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

- [ ] Write the failing test. `Packages/UNIShell/Tests/UNIShellTests/AssistantFailureTests.swift`:
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

- [ ] Run it and see it fail:
      ```bash
      swift test --package-path Packages/UNIShell --filter AssistantFailureTests
      ```
      Expected: `cannot find 'AssistantFailure' in scope` and, once it exists, `processFailed(exitCode:stderrTail:)` is missing (Task 11 brings stderr; **anticipate only the case signature** from Task 11 if you want to run this test in isolation — this step assumes the plan's order and leaves `cliFailureShowsStderr` marked with `.disabled("stderr chega na Task 11")` until then).

- [ ] Implement. `Packages/UNIShell/Sources/UNIShell/Support/AssistantFailure.swift`:
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
      And in the same file, the band shared by the panel and dashboard:
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
      Check the actual `ChromeButton` signature in `Packages/UNIShell/Sources/UNIShell/Windows/ChromeButton.swift` before compiling — the current panel use is `ChromeButton("Tentar de novo", appearance: .outlined, size: 11.5, height: 27, horizontalPadding: 10) { … }` (`AssistantPanel.swift:547-552`); use exactly this form.

- [ ] Run it and see it pass:
      ```bash
      swift test --package-path Packages/UNIShell --filter AssistantFailureTests
      ```
      Expected: `✔ Test run with 5 tests in 1 suite passed` (with `cliFailureShowsStderr` still disabled until Task 11).

- [ ] Prove it by mutation: change `.openSettings` to `.retry` in the `missingAPIKey` branch and confirm that `missingCredentialsOpenSettings` fails; undo.

- [ ] Commit:
      ```bash
      git add -A && git commit -m "feat: AssistantFailure traduz qualquer erro do assistente uma vez só

Quatro enums de adaptador, uma mensagem e uma recuperação. A faixa é a
mesma no painel e no dashboard. Spec 1.5.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
      ```

---

### Task 7: `AssistantMarkdown` leaves the popover (spec 1.7)

Markdown is rendered only in `ReaderIntelligencePopover` (`ReaderAssistantMarkdownBlock` at `:653`, `ReaderAssistantMarkdown` at `:732`); the panel and dashboard show raw `Text` (`AssistantPanel.swift:509`, `DashboardScreen.swift:430`).

**Files**
- Create `Packages/UNIShell/Sources/UNIShell/Support/AssistantMarkdown.swift` (extracted from `ReaderIntelligencePopover.swift:651-792`)
- Modify `Packages/UNIShell/Sources/UNIShell/Inbox/ReaderIntelligencePopover.swift` (delete the two definitions; the call at `:344` stays the same, only the type name changes)
- Create `Packages/UNIShell/Tests/UNIShellTests/AssistantMarkdownTests.swift`
- Modify `Packages/UNIShell/Tests/UNIShellTests/` — the suite that currently tests `ReaderAssistantMarkdownBlock.parse` (find it with `git grep -l ReaderAssistantMarkdownBlock -- Packages/UNIShell/Tests`) now cites `AssistantMarkdownBlock`

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

- [ ] Write the failing test. `Packages/UNIShell/Tests/UNIShellTests/AssistantMarkdownTests.swift`:
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

- [ ] Run it and see it fail:
      ```bash
      swift test --package-path Packages/UNIShell --filter AssistantMarkdownTests
      ```
      Expected: `cannot find 'AssistantMarkdownBlock' in scope`.

- [ ] Move the code. Create `Support/AssistantMarkdown.swift` with the complete contents of `ReaderIntelligencePopover.swift:651-792`, renaming `ReaderAssistantMarkdownBlock` → `AssistantMarkdownBlock` and `ReaderAssistantMarkdown` → `AssistantMarkdown`, and changing `private struct ReaderAssistantMarkdown` to `struct AssistantMarkdown` (it is no longer `private` because the panel, dashboard, and message window will use it). Delete the two definitions from the popover.

- [ ] Propagate the name:
      ```bash
      perl -pi -e '
        s/\bReaderAssistantMarkdownBlock\b/AssistantMarkdownBlock/g;
        s/\bReaderAssistantMarkdown\b/AssistantMarkdown/g;
      ' $(git ls-files 'Packages/UNIShell/**/*.swift')
      git grep -n ReaderAssistantMarkdown -- '*.swift' || echo "nome antigo eliminado"
      ```

- [ ] Adopt it in the panel. In `Packages/UNIShell/Sources/UNIShell/Inbox/AssistantPanel.swift`, inside `messageBubble` (line 509), replace
      ```swift
      Text(message.text)
          .font(theme.sans.font(size: 12.5))
          .foregroundStyle(theme.ink2.color)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      ```
      with
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
      (`message.kind` arrives in Task 8; until then use only `message.speaker == .user` and complete the condition in that task.)

- [ ] Run it and see it pass:
      ```bash
      swift test --package-path Packages/UNIShell
      ```
      Expected: green suite, including the popover suites that already tested the parser.

- [ ] Commit:
      ```bash
      git add -A && git commit -m "refactor: AssistantMarkdown sai do popover para o Support

Painel e dashboard mostravam Text cru; a mesma resposta virava lista no
leitor e parágrafo colado no painel. Spec 1.7.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
      ```

---

### Task 8: `AssistantConversation`, the sole state machine (spec 1.3)

There are two today: the panel's (`AssistantPanel.swift:184-276`) and the one reimplemented in `DashboardScreen.run/runDraft/runSuggestion` (`:728-778`). Neither cancels; neither stores a `Task`; the dashboard draft goes through `answer()`, whose prompt asks for Markdown, and comes back with `**` and lists.

> **Conscious spec deviation, forced by Swift:** the spec requests `func briefing()` (§1.3) **and** `AssistantConversation.briefing: String?` (§2.5). Swift refuses: `invalid redeclaration of 'briefing()'` (verified with `swiftc`). The method keeps the spec's name; the property becomes `briefingText: String?`.

**Files**
- Create `Packages/UNIShell/Sources/UNIShell/Inbox/AssistantConversation.swift`
- Modify `Packages/UNIShell/Sources/UNIShell/Inbox/AssistantPanel.swift` (delete the class from lines 184–276; move `AssistantMessage`, `AssistantSpeaker`, `AssistantRequest`, and `AssistantPanelDebugState` to the new file; `AssistantPanel` starts **receiving** the conversation)
- Modify `Packages/UNIShell/Sources/UNIShell/Support/AssistantBridge.swift` (engine factory)
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

- [ ] Write the failing tests. `Packages/UNIShell/Tests/UNIShellTests/AssistantConversationTests.swift`:
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
      And in `AssistantConversation.swift` itself, the helper the tests use to wait for the stored `Task` without sleeping:
      ```swift
      #if DEBUG
      public extension AssistantConversation {
          /// Espera o pedido em voo terminar. Existe para o teste não precisar
          /// de `Task.sleep`, que é o que transforma suíte em loteria.
          func waitForIdle() async { await currentTask?.value }
      }
      #endif
      ```

- [ ] Run it and see it fail:
      ```bash
      swift test --package-path Packages/UNIShell --filter AssistantConversationTests
      ```
      Expected: `cannot find 'AssistantEngine' in scope`, `extra argument 'scope' in call`, `value of type 'AssistantConversation' has no member 'draftReply'`.

- [ ] Implement the machine. `Packages/UNIShell/Sources/UNIShell/Inbox/AssistantConversation.swift`:
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
      `currentTask` must be visible to the `#if DEBUG` extension in the same file: leave it `private` and keep the extension in the **same** file (an extension in the same file can see `private`).

- [ ] Build the engine in the bridge. Add to `Packages/UNIShell/Sources/UNIShell/Support/AssistantBridge.swift`:
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
      `AssistantBridge.answer` (lines 21–46 of the file) already removes the duplicate user turn; leave it as is, only change the history cap to `AssistantConversation.maximumHistoryTurns` when building `turns`:
      ```swift
      let turns = history.suffix(AssistantConversation.maximumHistoryTurns).map { message in
          AssistantTurn(
              role: message.speaker == .user ? .user : .assistant,
              text: message.text
          )
      }
      ```

- [ ] Make the panel receive the conversation instead of creating it. In `AssistantPanel.swift`, replace `@State private var conversation` (line 288) and the `init` (lines 299–322) with:
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
      The header now shows `conversation.destination.label.uppercased()` instead of `providerLabel`; the footer (`mode.footer`, line 620) now shows `conversation.destination.detail`; the error band (lines 532–565) is replaced by
      ```swift
      if let failure = conversation.failure {
          AssistantFailureBand(
              failure: failure,
              onRetry: conversation.retry,
              onOpenSettings: onOpenSettings
          )
      }
      ```
      and `submit()` (line 629) becomes `conversation.submit()`; `suggestionButton` calls `conversation.run(suggestion)` without a `Task`; the clear button calls `conversation.clear`.

- [ ] Closing the surface cancels. In `AssistantPanel.body`, add after `.accessibilityIdentifier("local-assistant-panel")`:
      ```swift
      .onDisappear { conversation.cancel() }
      ```
      and change the identifier to `"assistant-panel"` (the "local" copy disappears here too). Update `AssistantPanelTests` and `InboxAssistantIntegrationTests` that look for the old identifier:
      ```bash
      git grep -n 'local-assistant-panel' -- '*.swift'
      ```

- [ ] Run it and see it pass:
      ```bash
      swift test --package-path Packages/UNIShell --filter AssistantConversationTests
      swift test --package-path Packages/UNIShell
      ```
      Expected: `✔ Test run with 8 tests in 1 suite passed`, followed by the full green suite. `InboxScreen`, `MessageWindow`, `ReaderPane`, and `DashboardScreen` still use the old path — if compilation breaks there, Task 9 moves them; in this task, do the minimum needed to compile (construct the `AssistantConversation` where the panel is currently constructed).

- [ ] Prove it by mutation: change `kind: .draft` to `kind: .message` in the `.draftReply` branch and confirm that `draftReplyUsesTransform` fails; undo. Change `engine.draftReply(request)` to `engine.answer(request)` and confirm the same test fails because `spy.answers` is not empty; undo. Change `maximumHistoryTurns` to 20 and confirm that `historyIsCappedAtSixteen` fails; undo.

- [ ] Commit:
      ```bash
      git add -A && git commit -m "feat: AssistantConversation é a única máquina de estado

Transcript, isLoading, failure e Task numa dona só; draftReply passa por
transform(.draftReply) e vira turno .draft; histórico 16 em toda
superfície; cancel() de verdade. Spec 1.3.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
      ```

---

### Task 9: Dashboard, message window, and popover consume the conversation (spec 1.3)

`DashboardScreen.run/runDraft/runSuggestion` disappear. "Gerar rascunho" now calls `draftReply()`.

**Files**
- Modify `Packages/UNIShell/Sources/UNIShell/Inbox/DashboardScreen.swift` (`init` at `:37-64`; `transcriptList` at `:429-447`; `draftButton` at `:448-465`; `askScope`/`run` at `:695-778`)
- Modify `Packages/UNIShell/Sources/UNIShell/Inbox/InboxScreen.swift` (`assistantPanel` at `:660-676`; `askAssistant` at `:686-712`)
- Modify `Packages/UNIShell/Sources/UNIShell/Windows/MessageWindow.swift` (`:18-37`, `:70-82`)
- Modify `Packages/UNIShell/Sources/UNIShell/Inbox/ReaderIntelligencePopover.swift` (receives `AssistantConversation`)
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
`transcript`, `draft`, and `onAsk` are removed from `init`: the transcript is now `conversation.messages`, the field is `conversation.draft`, and the route is `conversation.ask/draftReply`.

**Steps**

- [ ] Write the failing test. Add to `Packages/UNIShell/Tests/UNIShellTests/DashboardScreenTests.swift`:
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
      The second test reads its own source file: it is deliberately crude. The spec says to **remove** the three methods, and no behavioral assertion proves removal—only the absence of the text proves it.

- [ ] Run it and see it fail:
      ```bash
      swift test --package-path Packages/UNIShell --filter DashboardScreenTests
      ```
      Expected: `extra argument 'conversation' in call` and, in `dashboardHasNoOwnStateMachine`, four `#expect` assertions failing with `Expectation failed: !source.contains("private func run(")`.

- [ ] Replace the dashboard `init` and body. In `DashboardScreen.swift`:
      - remove `@Binding var transcript`, `@Binding var draft`, `let onAsk`, `@State private var loading`, `@State private var errorMessage`, `static let briefingQuestion` (it is now `AssistantConversation.briefingQuestion`), and the three methods `run`, `runDraft`, `runSuggestion` (lines 728–778);
      - add `let conversation: AssistantConversation` and `let onOpenSettings: () -> Void`;
      - `transcriptList` (line 429) now iterates `conversation.messages` and renders:
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
      - `draftButton` (line 448) becomes:
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
      - the error band becomes
        ```swift
        if let failure = conversation.failure {
            AssistantFailureBand(
                failure: failure,
                onRetry: conversation.retry,
                onOpenSettings: onOpenSettings
            )
        }
        ```
      - the generated briefing appears above the field, on a flat surface with a hairline (no floating card—the band designed in §2.2 belongs to sub-project 2):
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
      - the field shows the destination below:
        ```swift
        Text(conversation.destination.label)
            .font(theme.sans.font(size: 11))
            .foregroundStyle(theme.ink3.color)
        ```
      - `DashboardMailSheet`'s `onDraft` (line 92) becomes `{ message in readingMailID = nil; selectedMailID = message.id; conversation.draftReply() }`.

- [ ] Conversation owner in `InboxScreen`. In `InboxScreen.swift`, replace `@State private var assistantTranscript`/`assistantDraft` (search with `git grep -n 'assistantTranscript\|assistantDraft' -- Packages/UNIShell`) with:
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
`openWorkspaceAssistant()`/`openEmailAssistant()` now assign `assistantConversation = makeConversation(for: scope)`; `closeAssistant()` calls `assistantConversation?.cancel()`. `assistantPanel` passes `conversation:` and `onOpenSettings: openAccounts`.

- [ ] `MessageWindow` receives the conversation. In `MessageWindow.swift`, replace `textAssistant`/`assistantSettings`/`assistantProviderLabel` (lines 18–19, 49) with `let conversation: AssistantConversation?` and pass `conversation` to `AssistantPanel` (line 70). The constructor is `App/OkamiUNIApp.swift`, in the `UNIWindow.message` scene.

- [ ] `ReaderIntelligencePopover` receives the conversation. Replace the `onAsk`/internal state with the same pattern: `let conversation: AssistantConversation`, `onGenerateReply` becomes `conversation.draftReply()`, and "Usar no composer" reads `conversation.messages.last(where: { $0.kind == .draft })?.text`. `ReaderPane.generateReply(for:)` (`:870-892`) is deleted: it existed only for the popover, and the route is now the same `transform(.draftReply)` path through the conversation.

- [ ] Run and see it pass:
      ```bash
      swift test --package-path Packages/UNIShell
      xcodegen generate && xcodebuild -project OkamiUNI.xcodeproj -scheme OkamiUNI -configuration Debug build 2>&1 | grep -E "error:|BUILD"
      ```
      Expected: green suite and `** BUILD SUCCEEDED **`.

- [ ] Commit:
      ```bash
      git add -A && git commit -m "refactor: dashboard, janela e popover usam a mesma conversa

Três caminhos de gerar rascunho viraram um: transform(.draftReply). O
dashboard perde run/runDraft/runSuggestion e o estado duplicado.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
      ```

---

### Task 10: `AssistantAvailability`, `didChange`, and honest presentation (spec 1.5)

`AssistantRouter.availability()` has no caller outside the tests; `IntelligencePresentation` is hard-coded as `.configuredAssistant` in `App/OkamiUNIApp.swift:136` and `:259`. There is no "not configured" state.

**Files**
- Create `Packages/UNISync/Sources/UNISync/AssistantAvailability.swift`
- Modify `Packages/UNISync/Sources/UNISync/AssistantRouter.swift` (`availability()` at `:59-102`)
- Modify `Packages/UNISync/Sources/UNISync/AssistantSettingsStore.swift`
- Modify `Packages/UNISync/Sources/UNISync/AppComposition.swift`
- Modify `Packages/UNIShell/Sources/UNIShell/Inbox/FolderSidebar.swift` (`IntelligencePresentation` at `:11-84`)
- Modify `App/OkamiUNIApp.swift` (`:136`, `:259`)
- Create `Packages/UNISync/Tests/UNISyncTests/AssistantAvailabilityTests.swift`
- Modify `Packages/UNIShell/Tests/UNIShellTests/IntelligenceFooterTests.swift`

> **Conscious deviation from the spec:** the spec says that `AssistantRouter.availability()` "becomes" `AssistantAvailability`. It cannot: `availability()` is a `TextAssisting` requirement and returns `AppleIntelligenceAvailability`; `AssistantAvailability` lives in `UNISync` and carries `AssistantDestination`, which `UNICore` cannot see. The rich method is named `assistantAvailability()`; the protocol method is derived from it, and this is how the analysis queue and `MessageIntelligenceCoordinator` continue to work.

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

- [ ] Write the failing test. `Packages/UNISync/Tests/UNISyncTests/AssistantAvailabilityTests.swift`:
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

- [ ] Run it and see it fail:
      ```bash
      swift test --package-path Packages/UNISync --filter AssistantAvailabilityTests
      ```
      Expected: `cannot find 'AssistantAvailability' in scope` and `value of type 'AssistantSettingsStore' has no member 'addDidChangeHandler'`.

- [ ] Implement `AssistantAvailability`. `Packages/UNISync/Sources/UNISync/AssistantAvailability.swift`:
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

- [ ] Publish changes from the preference store. In `AssistantSettingsStore.swift`, add to the class body:
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
      and, at the end of `save(_:)` (line 49), after `cached = normalized` and **outside** the lock scope:
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

- [ ] Implement the calculation in the router. In `AssistantRouter.swift`, replace `availability()` (lines 59–102) with:
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

- [ ] Rework `IntelligencePresentation`. In `FolderSidebar.swift`, replace the enum (lines 11–84) with:
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
      `usesConfiguredProvider` is removed (it existed only to choose the glyph). `IntelligenceFooter` (from line 86 onward) gains, when `!isAvailable`, a second button:
      ```swift
      if !presentation.isAvailable {
          ChromeButton("Abrir Ajustes", appearance: .outlined,
                       size: 11, height: 24, horizontalPadding: 9,
                       action: onOpenSettings)
              .help(presentation.detail)
      }
      ```
      with a new `let onOpenSettings: () -> Void` in the struct; `SidebarRail` passes the same closure.

- [ ] Wire it into the composition. In `AppComposition.swift`, add the property and instantiate it in `make` (lines 148–158):
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
      and pass `assistantAvailability:` in both `return AppComposition(...)` statements in the function.

- [ ] Update the app wiring. In `App/OkamiUNIApp.swift`, on lines 136 and 259, `intelligencePresentation: .configuredAssistant` becomes:
      ```swift
      intelligencePresentation: IntelligencePresentation(composition.assistantAvailability.availability),
      ```
      and the main scene gains, in `.task`, the initial calculation:
      ```swift
      .task { await composition.assistantAvailability.refresh() }
      ```

- [ ] Update `IntelligenceFooterTests`: `allCases` no longer exists; the table at line 18 now lists the cases by hand, and the assertions on lines 66–78 about `.configuredAssistant`/`.available` become:
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

- [ ] Run and see it pass:
      ```bash
      swift test --package-path Packages/UNISync
      swift test --package-path Packages/UNIShell
      xcodegen generate && xcodebuild -project OkamiUNI.xcodeproj -scheme OkamiUNI -configuration Debug build 2>&1 | grep -E "error:|BUILD"
      ```

- [ ] Prove by mutation: make `assistantAvailability()` always return `.ready(destination)` and confirm that `apiKeyMissingNeedsSetup`, `providerOAuthWithoutSession`, and `cliNotFoundNeedsSetup` fail; undo it.

- [ ] Commit:
      ```bash
      git add -A && git commit -m "feat: disponibilidade honesta do assistente na lateral

availability() deixa de não ter chamador; a apresentação ganha
needsSetup e needsSignIn, perde .configuredAssistant, e o botão
desabilitado explica o motivo com 'Abrir Ajustes'. Spec 1.5.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
      ```

---

### Task 11: CLI discovery cache and captured stderr (spec 1.6)

`AssistantCLIDiscovery().scan()` scans the disk for every request (`AssistantRouter.swift:42`), and the child process's stderr goes to `/dev/null` (`AssistantCLITextAssistant.swift:187`)—that is exactly where "not logged in" appears.

**Files**
- Create `Packages/UNISync/Sources/UNISync/CachedAssistantCLIDiscovery.swift`
- Modify `Packages/UNISync/Sources/UNISync/AssistantCLITextAssistant.swift` (`AssistantCLITextAssistantError` at `:301-323`; executor at `:118-200`; result handling at `:531-549`)
- Modify `Packages/UNISync/Sources/UNISync/AppComposition.swift`
- Modify `Packages/UNIShell/Sources/UNIShell/Windows/SettingsSections.swift` (invalidate on save)
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
- Consumes: `AssistantCLIProcessResult.standardError` (`AssistantCLITextAssistant.swift:10`)—the field **already exists** and has always arrived empty.

**Steps**

- [ ] Write the failing test. `Packages/UNISync/Tests/UNISyncTests/CachedAssistantCLIDiscoveryTests.swift`:
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
      And, in `AssistantCLITextAssistantTests.swift`:
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
      (`StubAssistantCLIExecutor` already exists in the current suite; if the local name is different, use the one that is there.)

- [ ] Run it and see it fail:
      ```bash
      swift test --package-path Packages/UNISync --filter 'CachedAssistantCLIDiscoveryTests|AssistantCLITextAssistantTests'
      ```
      Expected: `cannot find 'CachedAssistantCLIDiscovery' in scope`; and `processFailureCarriesStderr` fails because the thrown error is `.processFailed` without a payload.

- [ ] Implement the cache. `Packages/UNISync/Sources/UNISync/CachedAssistantCLIDiscovery.swift`:
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

- [ ] Capture stderr. In `AssistantCLITextAssistant.swift`:
      - in the executor, replace `process.standardError = FileHandle.nullDevice` (line 187) with a temporary file next to `stdout`, using the same pattern as lines 161–174:
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
        and, where the result is currently built with `standardError: Data()`, read the **tail** of 4 KiB:
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
      - the error case (line 306) becomes `case processFailed(exitCode: Int32, stderrTail: String)` and its description:
        ```swift
        case .processFailed:
            "O CLI de IA encerrou com erro."
        ```
      - result handling (lines 542 and 546–549) now carries the payload:
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
      Every remaining `catch { throw AssistantCLITextAssistantError.processFailed }` receives `(exitCode: -1, stderrTail: "")`.

- [ ] Wire in the cache. In `AppComposition.make`, before the router:
      ```swift
      let cliDiscovery = CachedAssistantCLIDiscovery()
      ```
      and pass `cliInstallationProvider: { cliDiscovery.installations() }` to `AssistantRouter`; expose `public let assistantCLIDiscovery: CachedAssistantCLIDiscovery` so Settings can invalidate it. In `SettingsSections.swift`, `save()` for AI (search for `private func save()` inside `GeneralSettingsView`) calls `assistantCLIDiscovery?.invalidate()` immediately after `settingsStore.save(draft)`.

- [ ] Record the flag date. Above `AssistantCLICommand.make` (`AssistantCLITextAssistant.swift:73-79`), add:
      ```swift
      // Conferido em 2026-09-01 contra os binários instalados nesta máquina:
      // `codex exec --json`, `claude --print --output-format json`,
      // `opencode --pure run --format json`. As flags existem; o defeito que
      // fazia o CLI parecer mudo era o stderr descartado, não o argv.
      ```
      The set that locks down argv remains unchanged.

- [ ] Run and see it pass:
      ```bash
      swift test --package-path Packages/UNISync
      ```
      Expected: green suite, and `cliFailureShowsStderr` from Task 6 can now be re-enabled:
      ```bash
      swift test --package-path Packages/UNIShell --filter AssistantFailureTests
      ```

- [ ] Prove by mutation: return `Data()` from `standardErrorTail` and confirm that `processFailureCarriesStderr` and `cliFailureShowsStderr` fail; undo. Make `installations()` always scan and confirm that `scansOncePerWindow` fails; undo.

- [ ] Commit:
      ```bash
      git add -A && git commit -m "fix: cache de 60 s na descoberta de CLIs e stderr que chega na tela

A varredura acontecia a cada pergunta e a causa real da falha ia para
/dev/null. Spec 1.6.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
      ```

---

### Task 12: OAuth coordinators become `actor` (spec 1.6)

`LiteLLMOAuthCoordinator` (`:25-26`) and `AssistantProviderOAuthCoordinator` (`:37-38`) are `@MainActor`: every remote call goes through the interface thread to read or renew a token.

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

- [ ] Write the failing test. Add to `Packages/UNISync/Tests/UNISyncTests/AssistantProviderOAuthTests.swift`:
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

- [ ] Run it and see it fail:
      ```bash
      swift test --package-path Packages/UNISync --filter AssistantProviderOAuthTests
      ```
      Expected: `cannot find 'AssistantProviderOAuthSessionState' in scope`.

- [ ] Convert `AssistantProviderOAuthCoordinator`. Replace `@MainActor public final class` (lines 37–38) with `public actor`, remove `public private(set) var status` (line 39), and store `private let sessionState: AssistantProviderOAuthSessionState`. Every point that currently writes `status = …` becomes:
      ```swift
      private func publish(_ status: AssistantProviderOAuthStatus) async {
          await MainActor.run { self.sessionState.apply(status) }
      }
      ```
      Wherever the coordinator presents system UI (browser/device login), the explicit jump to `MainActor.run` remains **at the presentation point**, rather than on the entire type: that was the cost that made every remote call cross the interface.

- [ ] Create the observable state, in the same file:
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

- [ ] Repeat for `LiteLLMOAuthCoordinator` (lines 25–29 and every point that writes `status`).

- [ ] Adjust composition and Settings. In `AppComposition.make` (lines 151–152):
      ```swift
      let liteLLMOAuthState = LiteLLMOAuthSessionState()
      let liteLLMOAuth = LiteLLMOAuthCoordinator(sessionState: liteLLMOAuthState)
      let assistantProviderOAuthState = AssistantProviderOAuthSessionState()
      let assistantProviderOAuth = AssistantProviderOAuthCoordinator(sessionState: assistantProviderOAuthState)
      ```
      and expose both states in `AppComposition` (`public let liteLLMOAuthState: LiteLLMOAuthSessionState`, and likewise for the other). In `SettingsSections.swift`, every read of `coordinator.status` becomes a read of the state; every coordinator method call gains `await`.

- [ ] Run and see it pass:
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

### Task 13: The copy stops lying (spec 1.2)

`AssistantScope.footer` says "Usa todas as caixas e a agenda carregadas neste Mac" (`AssistantPanel.swift:113`), and the waiting message says "Lendo o contexto local…" (`:572`) with Grok selected. `IntelligencePresentation.scopeLabel` said "· local".

**Files**
- Modify `Packages/UNIShell/Sources/UNIShell/Inbox/AssistantPanel.swift` (`:110-115`, `:567-578`)
- Modify `Packages/UNIShell/Sources/UNIShell/Inbox/ReaderIntelligencePopover.swift` (popover title)
- Modify `Packages/UNIShell/Sources/UNIShell/Inbox/DashboardScreen.swift` (field footer)
- Modify `Packages/UNIShell/Sources/UNIShell/Windows/SettingsSections.swift` (`:282-283`, `:332`, `:1719-1736`)
- Modify `Packages/UNIShell/Tests/UNIShellTests/AssistantPanelTests.swift`

**Steps**

- [ ] Write the failing test. Add to `AssistantPanelTests.swift`:
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

- [ ] Run it and see it fail:
      ```bash
      swift test --package-path Packages/UNIShell --filter AssistantPanelTests
      ```
      Expected: `value of type 'AssistantScope' has no member 'footer(for:)'`.

- [ ] Implement. In `AssistantPanel.swift`, replace `var footer: String` (lines 110–115) with:
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
      `loadingBand` (line 567) now uses `conversation.scope.loadingLabel(for: conversation.destination)`; the composer (line 620) uses `conversation.scope.footer(for: conversation.destination)`.

- [ ] Scan the rest of the copy:
      ```bash
      git grep -n -i 'neste Mac\|processamento local\|contexto local\|assistente local\|IA local\|Nada sai' -- 'Packages/*/Sources' 'App'
      ```
      Every occurrence that does **not** consult `AssistantDestination.isLocal` is corrected:
      - `SettingsSections.swift:282-283`—the `SettingsNotice` for "Processamento local" remains, but only in the `.foundationModels` branch (which is already the case), and the text becomes "Perguntas e escrita usam o Foundation Models deste Mac. A análise automática de mensagens segue a rota escolhida abaixo." (the route is no longer always local after Task 14).
      - `SettingsSections.swift:332`—the `assistantRoutingNotice` text drops the promise about the TL;DR: "Este é o destino usado quando você aciona Resumo, Pontos-chave, Insights ou Gerar resposta."
      - `SettingsSections.swift:1719-1736`—`interactiveProviderLabel` is removed; its three callers (`:337`, `InboxScreen.swift:674`, `MessageWindow.swift:49`) now pass `AssistantDestination(settings: …).label`.
      - `ReaderIntelligencePopover`—the popover title gains `· \(conversation.destination.label)`.

- [ ] Run and see it pass:
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

### Task 14: Automatic analysis with opt-in and a queue that pauses (spec 1.8)

Persisted analysis is always `FoundationModelsMessageAnalyzer` (`AppComposition.swift:148`), regardless of the provider—and it is the only thing in the app that runs **without** the person asking. Making it remote without opt-in would send every received message to a server.

> **Conscious deviation from the spec:** it says "persisted `paused(reason)` state in `sync_state`." The `sync_state` table has `accountID TEXT NOT NULL REFERENCES account(id)` (`SyncDatabase.swift:231-239`), and foreign keys are enabled: **without a connected account there would be nowhere to write**—exactly the lesson already recorded in `docs/decisoes-de-engenharia.md` about `created_agenda_item`. And the queue is global, not per account. Migration `v15` creates `analysis_queue_state`, a single-row table.

**Files**
- Modify `Packages/UNISync/Sources/UNISync/AssistantSettings.swift` (`currentSchemaVersion` at `:430`; `migrated()` at `:465-485`; `CodingKeys`/`init(from:)`/`encode` at `:503-546`)
- Modify `Packages/UNISync/Sources/UNISync/Database/SyncDatabase.swift` (new migration after `v14`, `:629-632`)
- Create `Packages/UNISync/Sources/UNISync/Database/AnalysisQueueState.swift`
- Create `Packages/UNISync/Sources/UNISync/RoutedMessageAnalyzer.swift`
- Create `Packages/UNISync/Sources/UNISync/TextAssistantMessageAnalyzer.swift`
- Modify `Packages/UNISync/Sources/UNISync/MessageIntelligenceCoordinator.swift` (`processPending` at `:88-160`)
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

- [ ] Write the failing tests. `Packages/UNISync/Tests/UNISyncTests/RoutedMessageAnalyzerTests.swift`:
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
      And, in `MessageIntelligenceCoordinatorTests.swift`:
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
      And, in `AssistantSettingsTests.swift`:
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

- [ ] Run them and see them fail:
      ```bash
      swift test --package-path Packages/UNISync --filter 'RoutedMessageAnalyzerTests|MessageIntelligenceCoordinatorTests|AssistantSettingsTests'
      ```
      Expected: `cannot find 'AutomaticAnalysisRoute' in scope`, `extra argument 'automaticAnalysis' in call`, `has no member 'queueState'`.

- [ ] Add the preference. In `AssistantSettings.swift`, before `AssistantSettings`:
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
      and, in the body of `AssistantSettings`:
      ```swift
      public static let currentSchemaVersion = 5
      // …
      public var automaticAnalysis: AutomaticAnalysisRoute
      ```
      with `automaticAnalysis: AutomaticAnalysisRoute = .onDeviceOnly` in `init`, `case automaticAnalysis` in `CodingKeys`, and in `init(from:)`:
      ```swift
      // Documento v4 não conhecia a rota. `onDeviceOnly` é o único padrão que
      // não muda o comportamento de quem já tinha o app instalado.
      automaticAnalysis = try values.decodeIfPresent(
          AutomaticAnalysisRoute.self, forKey: .automaticAnalysis
      ) ?? .onDeviceOnly
      ```
      and `try values.encode(automaticAnalysis, forKey: .automaticAnalysis)` in `encode`.

- [ ] Migration `v15`. In `SyncDatabase.swift`, immediately after the `v14` block (line 629):
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

- [ ] Create the state. `Packages/UNISync/Sources/UNISync/Database/AnalysisQueueState.swift`:
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

- [ ] Create the analysis router. `Packages/UNISync/Sources/UNISync/RoutedMessageAnalyzer.swift`:
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

- [ ] Create the JSON analyzer. `Packages/UNISync/Sources/UNISync/TextAssistantMessageAnalyzer.swift`:
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
      **Before writing**, check the actual signature of `DetectedEvent.init` in `Packages/UNICore/Sources/UNICore/DetectedEvent.swift` and that of `MailCategory` in `.../MailCategory.swift`, and use exactly the labels that exist there; the `Output.Event.validated` above assumes `title/dayOffset/startMinute/endMinute`.

- [ ] Pause the queue. In `MessageIntelligenceCoordinator.swift`:
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
      and, inside `processPending`, immediately after the `isProcessing` guard (line 89):
      ```swift
      guard case .running = queueState() else { return 0 }
      ```
      and in the generic `catch` (lines 147–157):
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
      A success resets `consecutivePolicyFailures` (immediately after `if saved { completed += 1 }`).

- [ ] Compose it. In `AppComposition.make`, replace line 148:
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

- [ ] Show the pause. In `FolderSidebar.swift`, below `IntelligenceFooter`:
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
      `InboxScreen` receives `let analysisPause: (reason: String, retry: () -> Void)?` and draws the band when it is non-`nil`; `App/OkamiUNIApp.swift` feeds it from `composition.intelligence?.queueState()`.

- [ ] Toggle in Settings. In `SettingsSections.swift`, inside `assistantCard`, after `assistantRoutingNotice`, only for a remote destination:
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

- [ ] Run and see it pass:
      ```bash
      swift test --package-path Packages/UNISync
      swift test --package-path Packages/UNIShell
      xcodegen generate && xcodebuild -project OkamiUNI.xcodeproj -scheme OkamiUNI -configuration Debug build 2>&1 | grep -E "error:|BUILD"
      ```

- [ ] Prove by mutation: change `?? .onDeviceOnly` to `?? .configuredProvider` in `init(from:)` and confirm that `migratesToSchemaFive` and `defaultsToOnDevice` fail; undo. Change `failuresBeforePause` to 30 and confirm that `threeAuthFailuresPauseTheQueue` fails; undo. Delete the `input.body.contains(evidence)` check and confirm that `strictJSONValidation` fails; undo.

- [ ] Commit:
      ```bash
      git add -A && git commit -m "feat: análise automática remota é opt-in, e a fila pausa

Schema v5 com automaticAnalysis = .onDeviceOnly, RoutedMessageAnalyzer,
TextAssistantMessageAnalyzer com JSON estrito e evidência literal, e
pausa persistida depois de três falhas de ambiente. Spec 1.8.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
      ```

---

### Task 15: Workspace prompt golden and the router coverage that was missing (spec 1.9)

`AssistantRouterTests` does not cover `.cli` or `.providerOAuth`, and there is no golden for what leaves the machine in the workspace context—adding a new context field currently breaks nothing.

**Files**
- Create `Packages/UNISync/Tests/UNISyncTests/Golden/workspace-prompt.txt`
- Modify `Packages/UNISync/Tests/UNISyncTests/AssistantPromptTests.swift`
- Modify `Packages/UNISync/Tests/UNISyncTests/AssistantRouterTests.swift`
- Modify `Packages/UNISync/Package.swift` (declare the golden resource)

**Interfaces**
- Consumes: `AssistantPrompt.render(_:budget:)` (Task 4), `AssistantRouter` (Tasks 4 and 10), `CachedAssistantCLIDiscovery` (Task 11).

**Steps**

- [ ] Declare the resource. In `Packages/UNISync/Package.swift`, in the test target:
      ```swift
      .testTarget(
          name: "UNISyncTests",
          dependencies: ["UNISync"],
          resources: [.copy("Golden")]
      )
      ```
      (keep any dependencies already there; only add `resources:`.)

- [ ] Write the failing golden. In `AssistantPromptTests.swift`:
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

- [ ] Run it and see it fail:
      ```bash
      swift test --package-path Packages/UNISync --filter AssistantPromptTests
      ```
      Expected: the resource `#require` fails—the file does not exist.

- [ ] Generate the golden **once**, checking it visually before saving. Temporarily add `print(rendered)` to the test, run with `--filter workspacePromptGolden`, read the entire output (it must contain `<workspace-summary>`, `<workspace-emails priority-first="flagged-unread-recent">`, `<workspace-agenda chronological="true">`, and `<workspace-pending-items>`), and only then save the text to `Packages/UNISync/Tests/UNISyncTests/Golden/workspace-prompt.txt`. Remove the `print`.

- [ ] Prove that the golden is useful: add any field to the render (for example `threadCount:` inside `<email>`) and confirm that the test fails; undo.

- [ ] Cover `.cli` in the router. In `AssistantRouterTests.swift`:
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
      `RecordingAssistantCLIExecutor` stores the last `AssistantCLIProcessRequest` and returns valid output in the format of each CLI (`AssistantCLIResponseFormat`, `AssistantCLITextAssistant.swift:559-583`); `AlwaysAuthorizedProviderOAuth` implements `AssistantProviderOAuthTokenProviding` by returning `true`/`"token"`; `Counter` is the same one from Task 11. Put all three in `Packages/UNISync/Tests/UNISyncTests/Fixtures/`, alongside the helpers already there.

- [ ] Cover `.providerOAuth` xAI with the timeout reaching the adapter:
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
      Check `Packages/UNISync/Tests/UNISyncTests/Fixtures/` for the exact form of `StubURLProtocol.session(routes:)` and `StubURLProtocol.requests(for:)`—the router's current tests already use them (`AssistantRouterTests.swift:20-24, 41-46`)—and the real path of `AssistantProviderOAuthClient.xAIResponsesURL` to build the route.

- [ ] Run and see it pass:
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

### Task 16: Recording the decisions and the README copy (spec 1.10)

The README still promises "sem mandar conteúdo para servidor algum"—true in 2026-08, false since the provider became configurable.

**Files**
- Modify `docs/decisoes-de-engenharia.md` (append at the end, without deleting anything first)
- Modify `README.md` (Marco 5 line in the TL;DR: "✨ **Inteligência no dispositivo**: … sem mandar conteúdo para servidor algum."; Marco 5 table: "✨ **Análise local**"; "💬 **Perguntas contextuais**": "A resposta usa apenas o contexto local")

**Steps**

- [ ] Write the five entries in `docs/decisoes-de-engenharia.md`:
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

- [ ] Correct the README. Three changes:
      - Marco 5 item in the TL;DR:
        > ✨ **Inteligência com destino honesto**: o Foundation Models resume e identifica compromissos, responde perguntas sobre o email/conversa aberta e atua no composer (resumir, reescrever, encurtar, ajustar tom, corrigir e criar resposta) — e, quando você escolhe Grok, LiteLLM, Codex ou um CLI, o app **diz para onde o conteúdo vai**, em cada superfície, antes de mandar.
      - Marco 5 table, row "✨ **Análise local**": append "A análise automática continua no Mac por padrão; usar o provedor configurado nela é opt-in explícito, com a consequência escrita no toggle."
      - Marco 5 table, row "💬 **Perguntas contextuais**": replace "A resposta usa apenas o contexto local" with "A resposta usa apenas o contexto do app e diz quando a informação não está nele; o rodapé mostra o destino (`Neste Mac`, `Grok · xAI`, `LiteLLM · host`…)".

- [ ] Check that no unconditional promise remains:
      ```bash
      git grep -n -i 'sem mandar conteúdo para servidor algum\|apenas o contexto local\|nada sai deste Mac' -- README.md docs
      ```
      Expected: only the `AssistantDestination` line in the plan/decisions, never a README promise.

- [ ] Run the full suite and the app:
      ```bash
      for p in UNICore UNIDesign UNIShell UNISync; do (cd "Packages/$p" && swift test) || echo "FALHOU: $p"; done
      xcodegen generate && xcodebuild -project OkamiUNI.xcodeproj -scheme OkamiUNI -configuration Debug build 2>&1 | grep -E "error:|BUILD"
      ```
      Expected: four green suites and `** BUILD SUCCEEDED **`.

- [ ] Commit:
      ```bash
      git add -A && git commit -m "docs: registro do sub-projeto 1 e README sem promessa incondicional

Cinco entradas em decisoes-de-engenharia.md e a cópia do README passa a
depender do provedor escolhido. Spec 1.10.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
      ```

---

## Environment note: the UNIShell suite needs a graphical session

`Packages/UNIShell/Tests/UNIShellTests/RenderHarness.swift` hosts SwiftUI in an `NSWindow` positioned at −50,000 pt and never brought to the front: `Render.snapshot` records the bitmap, and `CliqueDeEnsaio` (`:198-223`) injects a mouse event inside the process.

Measured on this machine on 2026-09-01, and applicable to anyone executing this plan:

- **Outside the sandbox**, the suite runs normally—`swift test --package-path Packages/UNIShell
  --filter DashboardScreenTests` finishes in **3.5 s**, `✔ Test run with 4 tests in 1 suite passed`,
  and `--filter HairlineThicknessTests` in 1.7 s.
- **Inside a sandboxed shell** (without access to the window server), the sets that synthesize clicks hang indefinitely: `-[NSWindow _handleMouseDownEvent:]` remains stuck in `__CFRunLoopServiceMachPort`. A hang, not a failure—no report line is produced.

Therefore: run the UNIShell suite in a real graphical session. If you are an agent with a sandboxed shell, disable the sandbox for this suite or ask the project owner to run it; and do not confuse the hang with a defect in the code you just wrote. It is the same ground as the decision already recorded, "`NSApp.postEvent` mata um processo de teste em silêncio".

---

## Self-review

### Spec coverage, item by item

| Spec item | Where |
|---|---|
| 1.1 Renames (table) | Task 1 (text contract) and Task 2 (analysis, bridge, panel, prompt) |
| 1.2 `AssistantDestination` + copy | Task 3 (the value) and Task 13 (adoption in panel, dashboard, popover, Settings) |
| 1.3 Unified `AssistantConversation` | Task 8 (machine, `ask/draftReply/summarize/briefing/cancel/clear/retry`, `kind: .draft`, history 16, `emptyResponse`) and Task 9 (the surfaces; `run/runDraft/runSuggestion` removed) |
| 1.4 Budget, timeouts, language | Task 4 (`maximumTextCharacters`, `maximumWorkspaceEmails`, `maximumWorkspaceAgendaItems`, `maximumCustomInstructionCharacters`, 120 s, `timeoutIntervalForResource`) and Task 5 (language always emitted) |
| 1.5 `AssistantAvailability`, `didChange`, `IntelligencePresentation`, `AssistantFailure` | Task 10 (availability, `addDidChangeHandler`, `AppComposition.assistantAvailability`, `needsSetup`/`needsSignIn`, button with reason and "Abrir Ajustes") and Task 6 (`AssistantFailure` + `AssistantFailureBand`) |
| 1.6 Coordinators, CLI cache, stderr | Task 12 (actors + observable state) and Task 11 (`CachedAssistantCLIDiscovery` 60 s + `invalidate()`, stderr 4 KiB, dated comment on flags) |
| 1.7 `AssistantMarkdown` | Task 7 |
| 1.8 `automaticAnalysis` opt-in | Task 14 (schema v5, `RoutedMessageAnalyzer`, `TextAssistantMessageAnalyzer`, pause after 3 failures, sidebar band, Settings toggle) |
| 1.9 Tests | Distributed: `AssistantRouterTests` `.cli`/`.providerOAuth`/timeout/cache → Task 15; `AssistantPromptTests` (100 thousand characters, 100 emails, golden) → Tasks 4 and 15; `AssistantConversationTests` → Task 8; `DashboardScreenTests` "Gerar rascunho" → Task 9; `AssistantAvailabilityTests` → Task 10; `AssistantFailureTests` → Task 6; `RoutedMessageAnalyzerTests` and `MessageIntelligenceCoordinatorTests` → Task 14; `AssistantBehaviorPreferencesTests` → Task 5 |
| 1.10 Recording | Task 16 |

No item from 1.1 to 1.10 is missing a task.

### What section 1 leaves ready for sections 2–4 (planned later, not here)

- `AssistantConversation.briefing()` and `briefingText` exist and are tested (§2.5).
- `AssistantConversation.briefingQuestion` is already the fixed text for §2.5.
- `AssistantMarkdown` is public within the package, ready for the briefing band in §2.2.
- `AssistantDestination.label` is already the label the dashboard header will show (§2.2).
- `MessageAnalysisResult` keeps the shape that §3.1 will extend with `triage`.
- `DashboardFocus` does **not** change contract in this section, as §2.3 requires.

### Three spec deviations, all deliberate and recorded in the body of the plan

1. **`AssistantConversation.briefing` property + `briefing()` method**—impossible in Swift (`invalid redeclaration`, checked with `swiftc`). The property is named `briefingText`. (Task 8)
2. **`AssistantRouter.availability()` "becomes" `AssistantAvailability`**—impossible without breaking the `TextAssisting` requirement, which lives in `UNICore` and cannot see `AssistantDestination`. The rich method is `assistantAvailability()`; the protocol method is derived from it. (Task 10)
3. **Pausing the queue in `sync_state`**—the table has `accountID REFERENCES account(id)` and the queue is global; without a connected account there would be nowhere to write. Migration `v15` creates `analysis_queue_state`, a single-row table. (Task 14)

### Marker scan

There is no "TBD", "similar to Task N", "add error handling", or "write tests" in the body of the tasks: every code step includes the code, and code repeated between tasks was repeated intentionally because the executor reads one task in isolation.

Four points ask for **a code check before writing**, and are marked as such inside the tasks (they are not placeholders—they are boundaries where an existing signature governs):
the exact form of `ChromeButton` (Task 6), that of `DetectedEvent.init` and `MailCategory` (Task 14), that of `StubURLProtocol` and the name of the CLI executor stub (Task 15), and the current names of the test helpers in `Packages/UNISync/Tests/UNISyncTests/Fixtures/` (Tasks 11 and 15).

### Name consistency across tasks

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
`AnalysisQueueStateStore`—used with the same spelling in every task that cites them.
`FoundationModelsTextAssistant`, `FoundationModelsMessageAnalyzer`, and
`FoundationModelsTextAssistantValidation` **keep** their names, as the spec requires.
