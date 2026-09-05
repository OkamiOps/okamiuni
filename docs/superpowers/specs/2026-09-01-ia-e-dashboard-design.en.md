# AI Assistant and Dashboard — design

> **Historical design and implementation record.** This document preserves the decisions made on its stated date and is not evidence of current behavior. [Leia o original em Português](2026-09-01-ia-e-dashboard-design.md).
>
> **AI-consent note.** The automatic-analysis and consent rules below are a historical record from before the 0.5.3 ruling. For current behavior, see the [0.5.4 README](../../../README.md).

Date: 2026-09-01. Status: approved in conversation, awaiting review by the owner.

This specification covers four subprojects that share the same architecture and
are executed in order, each with its own implementation plan in
`docs/superpowers/plans/`:

1. **Assistant core** — correct, unify, and be truthful about the provider.
2. **"Daily briefing" dashboard** — approved HTML mockup first, then SwiftUI.
3. **AI triage** — persisted analysis begins to say *why* an email matters.
4. **Agent with actions** — the assistant proposes typed actions; nothing runs without a click.

A subproject only starts when the previous one is green (it builds, the four-package
suite has no new failure, captures have been checked). Baseline measured on 2026-09-01 on
`main` (0a6330a): 4 pre-existing failures, none in AI or dashboard —
`DatabaseMailSourceTests.swift:57`, `DatabaseBodyFetcherTests.swift:180`,
`GmailMirrorTests.swift:110` (UNISync), and `QuickReplyBandTests.swift:817` (UNIShell).

---

## 0. Diagnosis that motivated this work

Complete map on 2026-09-01, with file and line at that date:

**AI workflow**

- Types and copy say "local" for remote providers: `OnDeviceTextAssisting`,
  `OnDeviceAssistantMailContext`, `LocalAssistantPanel`, and text such as "Usa todas as
  caixas e a agenda carregadas neste Mac" (`LocalAssistantPanel.swift:113`) and "Lendo o
  contexto local…" (`:572`) appear while Grok, LiteLLM, Codex, and CLI are selected.
- Commit `0a6330a` ("send full hydrated email to configured AI") only passed `Budget`
  into the email context. `FoundationModelsTextAssistantPrompt.transform` still truncates
  text at 8,000 characters (`FoundationModelsTextAssistant.swift:352`), and
  `render(_ workspace:)` (`:429`) ignores the budget and fixes 24 emails / 32 events.
- There are three "gerar rascunho" paths; only reader and composer use
  `transform(.draftReply)`. Dashboard (`DashboardScreen.swift:739`) and panel
  (`LocalAssistantPanel.swift:50`) send a free-form question through `answer()`, whose
  prompt asks for Markdown. The draft returns with `**` and lists.
- The `answer()` prompt opens with "Responda à pergunta atual em português do Brasil"
  (`:283`) *after* the language line from preferences, which is only emitted when the
  language is not pt-BR. The language preference never wins.
- Timeouts: API/LiteLLM 30 s (`AssistantRouter.swift:38`), CLI 60 s with a 120 s ceiling
  (`:55`), direct OAuth 120 s. The owner has already seen Grok time out.
- `LiteLLMOAuthCoordinator` and `AssistantProviderOAuthCoordinator` are `@MainActor`:
  every remote call passes through the interface thread to read or refresh a token.
  `AssistantCLIDiscovery().scan()` scans disk on every request (`AssistantRouter.swift:42`).
- `AssistantRouter.availability()` has no caller outside tests. `IntelligencePresentation`
  is fixed `.configuredAssistant` in `App/OkamiUNIApp.swift:136` and `:259`; there is no
  "not configured" state.
- Four error enums (`OnDeviceTextAssistantError`, `OpenAICompatibleTextAssistantError`,
  `AssistantProviderOAuthTextAssistantError`, `AssistantCLITextAssistantError`) are flattened
  into `localizedDescription` without a recovery action. CLI stderr goes to `/dev/null`.
- Markdown is rendered only in `ReaderIntelligencePopover` (`ReaderAssistantMarkdown`).
  Panel and dashboard show raw `Text`.
- `DashboardScreen.run()` reimplements the state machine of `LocalAssistantConversation`.
- Persisted analysis per message (`MessageIntelligenceCoordinator`) is always
  `FoundationModelsMessageAnalyzer` (`AppComposition.swift:148`), regardless of provider.
- Tests: `AssistantRouterTests` does not cover `.cli` or `.providerOAuth`; there is no
  dashboard-assistant test, nor a golden for what leaves the machine in workspace context.
- CLI flags (`--safe-mode`, `--tools ""`, `--no-chrome`, `codex exec --json`,
  `opencode --pure run --format json`) **were checked in installed binaries on 2026-09-01
  and exist**. The real problem is discarded stderr.

**Dashboard**

- It is the only screen with floating cards and its own shadow (`DashboardScreen.swift:604-621`),
  literal 20/14 radii, sans titles, and `Color.black.opacity(...)` shadow outside tokens.
  The rest of the app uses serif in titles, mono `capsLabel` in labels, and flat surfaces
  separated by hairlines. The prototype in `design/` has no dashboard screen.
- Three green/orange/cyan `metricTile` items use `success/accent/info` as decoration;
  "Emails" shows the size of the slice (≤ 7), not of the mailbox.
- Half of the screen is the assistant showing one sentence; content is left in 340–440 pt.
- `DashboardFocus` calculates 7 emails and 8 events; the screen shows 3 and 3.
  `omittedMailCount` and `omittedMeetingCount` are never shown.
- Priority is heuristic from the "Precisa resposta / Lead / Prazo" tags that only exist in
  fixtures (`Fixtures.swift:96,127,154,182`). With a real account, nearly everything becomes "Média".
- `rankPill` collapses six `Reason` values into two labels. CTAs are duplicated. A robot is
  drawn with `Circle`. There is no quick action.
- Current tests do not lock pixels: `DashboardScreenTests` only asserts size and the
  `briefingQuestion` string.

---

## 1. Assistant core

### 1.1 Names

Rename across all packages and tests, without transition typealiases:

| Before | After |
|---|---|
| `OnDeviceTextAssisting` | `TextAssisting` |
| `OnDeviceAssistantMailContext` (+ `+Message` extension) | `AssistantMailContext` |
| `OnDeviceAssistantConversation` / `OnDeviceAssistantTurn` / `OnDeviceAssistantTurnRole` | `AssistantConversationSnapshot` / `AssistantTurn` / `AssistantTurnRole` |
| `OnDeviceWritingAction` | `WritingAction` |
| `OnDeviceTextAssistantError` | `TextAssistantError` |
| `OnDeviceAssistantBridge` | `AssistantBridge` |
| `LocalAssistantPanel` / `LocalAssistantConversation` / `LocalAssistantMode` / `LocalAssistantSuggestion` | `AssistantPanel` / `AssistantConversation` / `AssistantScope` / `AssistantSuggestion` |
| `OnDeviceMessageAnalyzing` / `OnDeviceMessageAnalysisInput` / `OnDeviceMessageAnalysisResult` / `OnDeviceMessageAnalysisError` | `MessageAnalyzing` / `MessageAnalysisInput` / `MessageAnalysisResult` / `MessageAnalysisError` |
| `OnDeviceMessageAnalysisAvailability` | `AppleIntelligenceAvailability` (it is only about Foundation Models) |

`FoundationModelsTextAssistant` and `FoundationModelsMessageAnalyzer` keep their names:
they really are the on-device engine. `FoundationModelsTextAssistantPrompt` becomes
`AssistantPrompt` because all four adapters use it.

### 1.2 Copy

Remove every sentence that claims local processing without checking the provider. Replace it
with one `AssistantDestination` value (in `UNISync`, derived from `AssistantSettings`):

| Provider | `label` | `detail` |
|---|---|---|
| `.foundationModels` | "Neste Mac" | "Nada sai deste Mac." |
| `.providerOAuth` xAI | "Grok · xAI" | "Sai deste Mac para a xAI." |
| `.providerOAuth` codex | "Codex · ChatGPT" | "Sai deste Mac pelo Codex instalado." |
| `.openAICompatible` | "API · {host}" or "LiteLLM · {host}" | "Sai deste Mac para {host}." |
| `.cli` | "{Claude Code|Codex CLI|OpenCode} · CLI" | "Sai deste Mac pelo CLI instalado." |

The `label` appears in the `AssistantPanel` header, beside the dashboard field, in the
reader popover title, and in the footer of "Perguntar ao ambiente". The `detail` appears
in `IntelligencePresentation.detail` and in the tooltip.

### 1.3 One state machine

`AssistantConversation` (`@MainActor @Observable`, currently `LocalAssistantConversation`)
becomes the sole owner of the transcript, `isLoading`, `failure`, and `task`. `DashboardScreen`,
`AssistantPanel`, `MessageWindow`, and the reader popover each receive an instance through
injection; `DashboardScreen.run/runDraft/runSuggestion` are removed.

Public API:

```swift
func ask(_ question: String)              // answer()
func draftReply()                         // transform(.draftReply) sobre o contexto de email
func summarize()                          // answer() com pergunta fixa de resumo
func briefing()                           // answer() sobre o workspace, pergunta do §2.5
func cancel()
func clear()
func retry()
```

Rules:

- Every call stores the `Task`, and `cancel()` cancels it; closing the surface cancels it.
- History sent to the engine: the last 16 turns, on every surface.
- `draftReply()` only exists with `.email` or `.conversation` context; the button does not
  appear with `.workspace`. The result is email prose and enters the transcript as an
  assistant turn with `kind: .draft`, which the UI renders without Markdown and with
  "Usar no composer".
- An empty response becomes `TextAssistantError.emptyResponse`, with one shared copy.

### 1.4 Budget, timing, and prompt

- `AssistantPrompt.transform` receives `budget` and uses `budget.maximumTextCharacters`
  (new field: 8,000 in `.onDevice`, 400,000 in `.configured`) in `<untrusted-text>`.
- `AssistantPrompt.render(_ workspace:budget:)` uses `budget.maximumWorkspaceEmails`
  (24 / 256) and `maximumWorkspaceAgendaItems` (32 / 128).
- `customInstruction` is capped at `maximumCustomInstructionCharacters = 6_000`.
- Timeout: `AssistantRouter.requestTimeout` defaults to 120 s and is used for
  `.openAICompatible`; `cliRequestTimeout` defaults to 120 s with a 30–300 s range;
  `.providerOAuth` keeps `max(requestTimeout, 120)`. These adapters’
  `URLSessionConfiguration` receives `timeoutIntervalForResource = timeout` in addition to
  `timeoutIntervalForRequest`.
- `answerInstructions` no longer contains a language. `AssistantBehaviorPreferences.generatedInstructions()`
  always emits the language line, including for pt-BR. Test: the `english` preference produces
  a prompt without the string "português".

### 1.5 Availability and errors

`AssistantRouter` gains `assistantAvailability()` (`availability()` from the `TextAssisting`
protocol, which returns `AppleIntelligenceAvailability` and lives in UNICore, becomes derived from it):

```swift
enum AssistantAvailability: Sendable, Hashable {
    case ready(AssistantDestination)
    case needsSetup(AssistantDestination, reason: String)      // sem chave, endpoint inválido, CLI não encontrado
    case needsSignIn(AssistantDestination)                     // OAuth sem sessão
    case appleIntelligence(AppleIntelligenceAvailability)      // deviceNotEligible / notEnabled / modelNotReady
}
```

It is cheap: it reads `settingsStore.snapshot()`, checks credential presence (without
materializing it), OAuth-session presence (without refreshing), and the CLI cache. It makes
no network call.

`AppComposition` exposes `assistantAvailability` as an `@Observable` recomputed when
`AssistantSettingsStore` changes (the store starts publishing `didChange`). `OkamiUNIApp`
translates it into `IntelligencePresentation`, which gains the `needsSetup(detail:)` and
`needsSignIn(provider:)` cases and loses `.configuredAssistant`. `isAvailable` is `true` only
in `.ready`/`.available`. The disabled "Perguntar ao ambiente" button shows its reason and
an "Abrir Ajustes" link.

`AssistantFailure` (`UNIShell/Support/AssistantFailure.swift`) translates any `Error` into
`(message: String, recovery: Recovery?)`, with `Recovery` in
`{ retry, openSettings, reconnect(AssistantProviderOAuthKind) }`. Mapping is singular; the
four adapter enums remain as they are. `AssistantPanel` and dashboard render the same
`AssistantFailureBand`.

### 1.6 Executors and CLI

- `LiteLLMOAuthCoordinator` and `AssistantProviderOAuthCoordinator` become `actor`s. The
  Settings UI that currently observes them as `@MainActor` instead reads an `@Observable`
  state published by the actor (`sessionState`), without touching a token.
- `AssistantCLIDiscovery` gains `CachedAssistantCLIDiscovery` with a 60 s lifetime and
  `invalidate()` called when Settings is saved. The router uses the cache.
- `SystemAssistantCLIProcessExecutor` captures stderr (4 KiB ceiling, tail) and includes it
  in `AssistantCLITextAssistantError.processFailed(exitCode:stderrTail:)`. Copy shows the
  first stderr line when one exists.
- Current flags remain; the test that locks argv remains, with a dated comment saying which
  version of each CLI it was checked against.

### 1.7 Markdown

`ReaderAssistantMarkdown` and `ReaderAssistantMarkdownBlock` leave the popover for
`UNIShell/Support/AssistantMarkdown.swift` as `AssistantMarkdown`. Panel, dashboard, and
message window use it. `kind: .draft` turns do not pass through it.

### 1.8 Automatic analysis with opt-in

- `AssistantSettings` gains `automaticAnalysis: AutomaticAnalysisRoute` with the
  `onDeviceOnly` (default) and `configuredProvider` cases. `currentSchemaVersion` increases
  to 5; migration fills `onDeviceOnly`.
- `RoutedMessageAnalyzer: MessageAnalyzing` selects per call: `onDeviceOnly` →
  `FoundationModelsMessageAnalyzer`; `configuredProvider` → `TextAssistantMessageAnalyzer`,
  which asks the routed `TextAssisting` for JSON `{summary, detectedEvent?, category?}` with
  the same evidence contract (a date only with a literal excerpt of text) and validates it
  with strict `Decodable`. When the configured provider is `.foundationModels`, the two
  routes coincide.
- `MessageIntelligenceCoordinator.processPending` checks `analyzer.availability()`; for the
  remote route this is mapped `AssistantAvailability`. An authentication or network failure
  in three consecutive messages **pauses the queue** with persisted `paused(reason)` state in
  `analysis_queue_state` (new one-row table, migration `v15`; `sync_state` is per account and
  the queue is global), visible in the sidebar ("Análise pausada: {motivo} · Tentar de novo").
  It never silently falls back to the Mac.
- Settings: toggle "Analisar mensagens novas automaticamente com {label}" inside the
  provider card, with the sentence "Cada mensagem recebida sai deste Mac para {host}." It
  only appears for remote providers.
- **Ruling 2026-09-03**: a deliberately configured remote provider is consent; the default
  follows the provider (`AutomaticAnalysisRoute.default(for:)` — `configuredProvider` for
  remote/CLI, `onDeviceOnly` for Foundation Models) and the switch restricts to this Mac.
  `automaticAnalysisTouchedByUser` stores a manual choice: people who never touched it are
  migrated once on loading, with `automaticAnalysisSince` at today − 7 days (the entire
  collection remains the "Analisar o acervo" task, which asks for confirmation); people who
  touched it are not migrated. The `automaticAnalysisCoversMessage` gate does not change.

### 1.9 Subproject 1 tests

- `AssistantRouterTests`: `.cli` with every `AssistantCLIKind`; `.providerOAuth` xAI and
  codex (including codex with no binary → `executableNotFound`); 120 s timeout reaching the
  adapter; discovery cache used once across N calls.
- `AssistantPromptTests` (renamed): `transform` with `.configured` does not elide 100,000
  characters; workspace with 100 emails renders 100 in `.configured` and 24 in `.onDevice`;
  workspace-prompt golden over the fixtures (file in `Tests/Golden/`), which fails when a new
  field is added to the context.
- `AssistantConversationTests`: `draftReply()` calls `transform(.draftReply)` on a
  `TextAssisting` spy; `cancel()` during `ask` leaves state idle without an error; sent
  history has 16 turns with 20 accumulated.
- `DashboardScreenTests`: "Gerar rascunho" in the sheet calls `draftReply()`, not `ask()`.
- `AssistantAvailabilityTests`: every provider in every credential state.
- `AssistantFailureTests`: every adapter enum → message and recovery.
- `RoutedMessageAnalyzerTests` and `MessageIntelligenceCoordinatorTests`: route by
  configuration; pause after three authentication failures; manual resume.
- `AssistantBehaviorPreferencesTests`: English language does not produce "português".

### 1.10 Record

New entries in `docs/decisoes-de-engenharia.md`: "A 30 s timeout was wrong for a 400-thousand-
character prompt", "No silent provider fallback", "Subscription Codex runs through the CLI",
"Untrusted data goes between escaped delimiters", "Opt-in for remote analysis and a queue that
pauses instead of falling back to the Mac".

---

## 2. "Daily briefing" dashboard

### 2.1 Process

1. `design/07-dashboard.html`: its own file, with the same token `<style>` as the prototype
   (copied, not linked — the 220 KB `.dc.html` is not edited), the same 58 px chrome with
   Dashboard/Caixa/Agenda tabs, 1440×916, and a `data-theme` selector to check `okami`,
   `tinta`, `noite`, and `neon`. Designed states: full, empty, with generated briefing, with
   transcript open.
2. The owner approves the mockup (or requests adjustments) before any Swift.
3. SwiftUI implementation against the mockup, measured in `RenderHarness`; divergence is a
   bug with a number on both sides, as README principle 1 requires.

### 2.2 Layout

Below the chrome, `paper` background and padding 22 like other screens:

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

- **Header**: date in `capsLabel`, `theme.serif` 28 semibold greeting in `ink`,
  "Gerar briefing" button in `ChromeButton` style with `AssistantDestination.label` below in
  `ink3` 11. No emoji.
- **Briefing band**: `surface2` background, `line2` hairline above and below, model text in
  `AssistantMarkdown` with serif 15 body. "Gerar de novo" and close actions. Loading state:
  the band appears with "Lendo caixa e agenda…" and the theme spinner.
- **PRIORITIES**: `capsLabel` label with the count. Flush rows in the `MessageRow` language:
  account-ink bar on the left edge, sans 13 semibold sender, theme `subjectWeight/subjectSize`
  subject, mono 11 time on the right, and a `TintChip` below the subject with `Reason.label`
  (six reasons, colors: `needsReply` and `deadline` in `warning`, `lead` in `accent`,
  `flagged` in `info`, `unread` and `today` in `ink3`). Unread: `surface2` background;
  selected: `surface3`. Shows the 7 items in `DashboardFocus.mail`; "+ N na Caixa →" footer
  with `omittedMailCount` when > 0. Hover reveals three actions at right, in reader-button
  style: Responder, Arquivar, Depois. Clicking the row opens `DashboardMailSheet` as today.
  Context menu matches Caixa (`ContextMenus.messageRow`). Empty: "Nada pedindo uma decisão."
  in serif 15 + `ink3` explanatory line, like the `AgendaRail` "Dia livre".
- **Right column** (300 pt, `surface` background, `line` hairline on the left): the existing
  `AgendaRail`, unchanged; below it, `PENDÊNCIAS` in `capsLabel` with `focus.pending` in
  two-line rows (text + source in `ink3`), empty: "Nada pendente."
- **Assistant**: retain `DashboardAskField`, inside a `btn`/`btnLine` capsule with the ↑
  button; `AssistantDestination.label` below in `ink3`. With a transcript, an `AssistantPanel`
  in `embedded` mode grows above the field up to 40% of the column height, with internal
  scrolling; "Limpar" removes everything. `briefingQuestion` remains a suggested question
  when the transcript is empty.

Remove: `metricTile`, robot, `betaBadge`, duplicate `footerLink`, `board`,
`Spacer(minLength: 0)`, `Color.black.opacity`, 20/14 radii, and `theme.info.color.opacity(0.55)`.

### 2.3 Data

`DashboardFocus` does not change contract in this subproject. The screen consumes all of
`mail`, `omittedMailCount`, and `pending`; `meetings` stays with `AgendaRail`.
`visibleMail`/`visibleMeetings` are removed.

### 2.4 Quick actions

Reply → `onOpenComposer(.reply(messageID))` (the same reader route). Archive →
`ContextCommand.move(messageID:to: .archived)` through the same Caixa port (transactional
queue, undo in the bar). Later → `ContextCommand.move(messageID:to: .later)`. After
archive/later, the row disappears with the list’s standard animation and `DashboardFocus`
recalculates through `messagesRevision`.

### 2.5 Briefing

`AssistantConversation.briefing()` sends the fixed question to the workspace:

> "Faça um briefing do meu dia em até 120 palavras: o que exige resposta hoje, os
> compromissos de hoje em ordem, e o que pode esperar. Cite remetentes e horários."

The result lives in `AssistantConversation.briefingText: String?` (session-only, does not
persist; it cannot be named `briefing` because the method already occupies that name) and is
independent of the transcript. It only runs on click.

### 2.6 Tests

- `DashboardScreenTests`: render 1200×820 in four states (full, empty, briefing,
  transcript) in `okami` and `tinta`; priority row shows the correct `Reason.label` per
  fixture; "+ N na Caixa" appears with `omittedMailCount = 4` and disappears with 0; Archive
  calls `ContextCommand.move(.archived)` on a spy; Later calls `.later`; "Gerar briefing"
  calls `briefing()` rather than `ask()`; `briefingQuestion` is updated.
- `DashboardMockupParityTests`: widths (right column 300, padding 22, header height)
  measured in the harness and compared with mockup numbers, following the hairline-test pattern.

---

## 3. AI triage

### 3.1 Model

`MessageAnalysisResult` gains `triage: MessageTriage?`:

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

The evidence rule matches the appointment rule: `deadline` only persists if `evidence` is a
literal substring of analyzed text; otherwise validation discards it.

### 3.2 Persistence

`v16` migration in `SyncDatabase` (`v15` belongs to subproject 1): `triage TEXT NULL`
(JSON) column in `message_intelligence`, plus denormalized `triage_needs_reply INTEGER` and
`triage_deadline_at REAL` for ordering. `MessageIntelligenceStore` reads and writes all three.
`MailItem` gains hydrated `triage: MessageTriage?` in the existing `LEFT JOIN`
(`MessageIntelligenceStore.swift:77`).

### 3.3 Engines

- Foundation Models: `MessageAnalysisGeneratedOutput` gains fields through `@Generable`.
- `TextAssistantMessageAnalyzer`: requested JSON gains `triage`.
- Both `modelVersion` values increase; old records without `triage` are reprocessed by the
  queue when the body is available, with the same `prioritize(messageID:)`.

### 3.4 Ranking

`DashboardFocus.rank`: when `item.triage` exists, `needsReply` +100, `intent == .lead`
+80, `deadline` +70 if ≤ 24 h, +50 if ≤ 72 h, +30 after that; `urgency == .high` +20;
unflagged `intent` in `{newsletter, transactional}` is discarded. Without `triage`, current
tag heuristics remain. `Reason` does not change cases; its origin (triage or tag) is not shown.

### 3.5 Surfaces

- Dashboard chip already shows the reason (§2.2).
- After the summary, the reader TL;DR band gains "Precisa resposta" and "Prazo: qui 15h"
  when they exist, in the same mono/caps style.

### 3.6 Tests

`MessageTriageTests` (literal evidence required), `DashboardFocusTests` (order with present
triage beats tag order; flagged newsletter enters), `v15` migration round-trip, requested-
JSON golden for the remote provider.

---

## 4. Agent with actions

### 4.1 Contract

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

Closed allowlist. There is no send, delete, permanent delete, empty trash, move to an
arbitrary folder, or RSVP.

### 4.2 Model output

- Foundation Models: `answer()` gains an `answerWithProposals()` variant with `@Generable
  AssistantReply { text: String; proposals: [AssistantProposalOutput] }`.
- Remote/CLI: the prompt requests, at the end of the response, a single
  ```` ```okami-actions ```` block with JSON `{proposals: [...]}`. The parser extracts the
  block, removes it from displayed text, and decodes it with strict `Decodable`. An absent or
  invalid block = no proposals, no error.
- Validation in `AssistantProposalValidator`: every `messageID` must be in the
  `AssistantMailContext` sent in that call; `addToAgenda` requires persisted `DetectedEvent`;
  `reply.draft` goes through the same `FoundationModelsTextAssistantValidation.response`.
  A proposal with any invalid action is entirely discarded.

### 4.3 Interface

Proposals render as `AssistantProposalCard` below the turn: serif 14 title, action list in
sans 12 with the email subject resolved by the store, and "Executar" and "Ignorar" buttons.
Execute applies every action through the corresponding `ContextCommand` (same transactional
queue and undo); `reply` opens the composer through `ComposerSeed` with the draft and **does
not send**; `openMessage` opens the reader. After execution, the card becomes
"Feito · Desfazer" while the bar undo exists.

Surfaces: dashboard field, `AssistantPanel`, `MessageWindow`. The briefing (§2.5) begins to
use `answerWithProposals()` and shows up to 3 proposals below the band.

### 4.4 Tests

Block parser (present, absent, malformed, two blocks → only the last), validator
(an ID outside context discards the entire proposal; `addToAgenda` without event discards it),
execution calls the right `ContextCommand` on a spy and never `MailSendPort`, `reply` opens the
composer with the draft and sender `To`, prompt golden with the block instruction.

---

## 5. Out of scope

Response streaming; automatic fallback between providers; AI triggering itself
(besides the existing automatic analysis, which remains opt-in for remote); sending actions;
recurrence; CalDAV.

## 6. Execution

| Subproject | Implements | Tests | Review |
|---|---|---|---|
| 1 Core | `worker-opus` | `worker-sonnet` | orchestrator |
| 2 Dashboard (mockup and SwiftUI) | `worker-fable` | `worker-sonnet` | owner approves mockup; orchestrator reviews Swift |
| 3 Triage | `worker-opus` | `worker-sonnet` | orchestrator |
| 4 Agent | `worker-opus` | `worker-sonnet` | orchestrator |

Each subproject: its own plan through `writing-plans`, branch from
`claude/ai-workflow-dashboard-redesign-1e2d9c`, TDD as README requires ("teste que passa
com o código quebrado é defeito"), and `xcodebuild test` for all four packages green before
continuing.
