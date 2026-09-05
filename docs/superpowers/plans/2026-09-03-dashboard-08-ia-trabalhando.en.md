# Dashboard 08 — the AI at work · implementation plan

> **Historical note:** This implementation plan records the repository state, assumptions, and validation results from 2026-09-03. It may not reflect the current state.
>
> [Original in Portuguese — Dashboard 08 — a IA trabalhando · plano de implementação](2026-09-03-dashboard-08-ia-trabalhando.md)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development, one task at a time in the same worktree.

**Goal:** build the `design/08-dashboard-ia.dc.html` screen (approved on 2026-09-03) with the assistant drawer (09) and window (10), in Swift, on top of what already exists.

**Spec:** `docs/superpowers/specs/2026-09-01-ia-e-dashboard-design.md` (§2 dashboard, §3 triage, §4 agent with actions) + the measurements table at the top of `design/08-dashboard-ia.dc.html`. Where design 08 and §2.2 diverge, **08 prevails**.

## Global Constraints

- Swift 6 strict concurrency · macOS 26 · Swift Testing (never XCTest) · pt-BR throughout.
- Theme tokens only; `1/displayScale` hairline; `strokeBorder`; `radiusSmall` is the only radius. One color box on the screen (the hero).
- Pure logic in UNICore, `nonisolated`, with its own test. No decision in `static` inside a `View`.
- **The AI never acts on its own.** Every proposal becomes an action only after a click. Actions go through `ContextCommand` (transactional queue, undo).
- **Send** (2026-09-03 ruling): §4 prohibits the *AI* from sending, and that remains true. Sending a fully visible draft is the person sending: the preview sends directly through the normal outbox queue; a row with truncated text selects the row and requests a one-line confirmation first. Never send a draft the person has not seen in full.
- Anticipatory drafts and remote proposals follow the **same opt-in** as automatic analysis (`automaticAnalysis`, `automaticAnalysisSince`). Without opt-in, only Foundation Models anticipates.
- A learned rule ("Archive and learn") is per exact sender address, revocable in Settings, and appears in "Removed from the list".
- A test that passes with the defect restored is defective.
- The complete UNIShell suite hangs in this environment: use narrow filters, one at a time.

## Interfaces (what each task produces and the next consumes)

```swift
// UNICore — Tarefa 1
public struct DayPlan: Sendable, Hashable {
    public struct Hero: Sendable, Hashable { public let messageID: String; public let sentence: String; public let hasReadyDraft: Bool }
    public enum Proposal: Sendable, Hashable {
        case sendDraft(messageID: String, preview: String)            // "Resposta pronta. “…”"
        case later(messageID: String, until: Date, why: String)       // "Sem prazo… sexta 9h?"
        case archiveAndLearn(messageID: String, why: String)          // "Você nunca abriu…"
        case keep(messageID: String, why: String)                     // sem sugestão forte
    }
    public struct Row: Sendable, Hashable, Identifiable { public let id: String; public let item: DashboardFocus.MailItem; public let why: String; public let proposal: Proposal }
    public struct Section: Sendable, Hashable { public enum Kind: String { case waitingOnYou, due, lead }; public let kind: Kind; public let rows: [Row] }
    public struct Filter: Sendable, Hashable { public enum Category: String, CaseIterable { case people, deadlines, leads, broadcasts, newsletters }; public var on: Set<Category>; public var accounts: Set<String> }
    public struct Removed: Sendable, Hashable { public let messageID: String; public let subject: String; public let why: String }
    public struct ReplyBlock: Sendable, Hashable { public let day: Int; public let startMinute: Int; public let minutes: Int; public let messageIDs: [String] }
    public let hero: Hero?
    public let sections: [Section]
    public let counts: [Filter.Category: Int]
    public let removed: [Removed]
    public let replyBlock: ReplyBlock?
    public static func make(focus: DashboardFocus, drafts: [String: ReadyDraft], rules: [SenderRule], agenda: [AgendaItem], filter: Filter, now: Date, nowMinute: Int) -> DayPlan
}
public struct ReadyDraft: Sendable, Hashable, Codable { public let messageID: String; public let text: String; public let contentHash: String; public let modelVersion: String; public let usedAgenda: Bool }
public struct SenderRule: Sendable, Hashable, Codable { public let address: String; public let neverPriority: Bool; public let createdAt: Date }
public struct FreeSlots { public static func next(days: Int, minMinutes: Int, agenda: [AgendaItem], workday: ClosedRange<Int>, now: Date) -> [ (day: Int, start: Int, end: Int) ] }
```

## Tasks (one at a time, in this order)

### Task 1 · UNICore — `DayPlan`, `SenderRule`, `FreeSlots`

Pure. `make` decides: the hero (the oldest item waiting for a response with a ready draft; a sentence with waiting days and "yes or no" when the draft is short); sections; `why` per row (the question extracted by `MessageTriage`, the request, or the deadline); the per-row proposal (ready draft → `sendDraft`; no deadline and no draft → `later` on the next business day at 9:00; a sender the person has never opened (`isRead == false` in all of their messages) and that is a broadcast → `archiveAndLearn`); `removed` = what `SenderRule` and the broadcast barrier removed, with the reason; `replyBlock` = the first `FreeSlots` of ≥20 minutes after now, before the closest deadline; `counts` by category and application of `Filter`. Tests use the owner's seven emails as fixtures.

### Task 2 · UNISync — anticipatory draft and rules

- `ready_draft` table (v20 migration): `messageID`, `text`, `contentHash`, `modelVersion`, `usedAgenda`, `createdAt`. A reactive serial queue like the analysis queue: for every message with `needsReply` and no draft for the current hash, generate one through the router's `draftReply` — Foundation Models always; remote only under opt-in. If `MessageTriage.intent == .scheduling` or the text asks about availability, the prompt receives `FreeSlots.next(days: 14)` and the draft stores `usedAgenda = true`.
- `sender_rule` table (v20): `address`, `neverPriority`, `createdAt`. `ContextCommand.learnSender(address:neverPriority:)` persists it and is undoable.
- `AssistantAction` gains `.learnSender(address:)` and `.reserveBlock(day:start:minutes:title:)`; the §4 validator accepts them; `reply` continues to open the composer.

### Task 3 · UNIShell — dashboard 08

Rewrite `DashboardScreen` against the measurements table: one-line header; hero; text filter; sections; `DashboardRow` with no sidebar, with the account dot and the `↳` line; preview with the draft card **before** the summary; the day with the suggested block; the "Removed from the list" footer; and the "Ask · ⌘J" button. Follow the Send ruling. `Reserve` creates the event through the existing agenda `ContextCommand`. "Updated now · next in N min": the dashboard recalculates on every store change and on a five-minute clock. Render offscreen against the mockup in `okami` and `tinta`; test measurement parity.

### Task 4 · UNIShell — assistant drawer and window

`AssistantDrawer` over `InboxScreen` (440, right border, shadow, 45% background), `⌘J` toggles it, and Esc closes it. Reuse `AssistantConversation` with `answerWithProposals()` from §4; each proposal becomes an `AssistantProposalCard` (confirm button + "view"). Context: "your day" or the selected email, with a switcher. Starter chips. The ↗ icon pops out into `AssistantWindow` (its own scene, `⌘W`, one per app). Remove the list footer field.

### Task 5 · Final branch review, installation, `main`, release 0.4.0.
