import AppKit
import Foundation
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// Espião próprio desta suíte. O de `AssistantConversationTests` é privado
/// daquele arquivo — duas suítes não partilham espião por acidente.
private final class DashboardSpyAssistant: TextAssisting, @unchecked Sendable {
    struct TransformCall: Equatable {
        let text: String
        let action: WritingAction
    }

    let modelVersion = "spy/dashboard"
    var answerResult: Result<String, any Error> = .success("resposta")
    var transformResult: Result<String, any Error> = .success("Oi Marina,\n\nFechado.")
    private(set) var answers: [AssistantConversationSnapshot] = []
    private(set) var transforms: [TransformCall] = []

    func availability() async -> AppleIntelligenceAvailability { .available }

    func answer(
        question: String,
        in conversation: AssistantConversationSnapshot
    ) async throws -> String {
        answers.append(conversation)
        return try answerResult.get()
    }

    func transform(
        _ text: String,
        using action: WritingAction,
        context: AssistantMailContext?
    ) async throws -> String {
        transforms.append(.init(text: text, action: action))
        return try transformResult.get()
    }
}

/// O espião das ações rápidas: guarda o `ContextCommand` que a linha emite,
/// sem executar nada no store. É a mesma porta que a Caixa usa — o que este
/// caso prova é que o dashboard emite o comando certo, não que o store o
/// aplica (isso já tem teste em `UNICore`).
@MainActor
private final class CommandSpy {
    var commands: [ContextCommand] = []
}

@Suite("Dashboard")
@MainActor
struct DashboardScreenTests {

    /// Conversa que não fala com ninguém: as capturas do recorte não podem
    /// depender de provedor, e o dashboard não dispara nada sozinho.
    private func inertConversation(scope: AssistantScope = .email) -> AssistantConversation {
        AssistantConversation(
            scope: scope,
            context: .init(subject: "Caixa e agenda de hoje"),
            destination: .unconfigured,
            engine: AssistantEngine(supportsDraftReply: false) { _ in "" }
        )
    }

    private func spiedConversation(
        _ spy: DashboardSpyAssistant,
        mail: Message
    ) -> AssistantConversation {
        AssistantConversation(
            scope: .email,
            context: .init(subject: mail.subject, sender: mail.from.display),
            destination: .init(label: "Neste Mac", detail: "Nada sai deste Mac.", isLocal: true),
            engine: AssistantBridge.engine(
                using: spy,
                supportsDraftReply: true,
                mailContext: { AssistantMailContext(message: mail) }
            )
        )
    }

    /// A conversa do dashboard como o `InboxScreen` a monta: o escopo é
    /// resolvido na hora, a partir do email **selecionado**.
    private func dashboardConversation(
        _ spy: DashboardSpyAssistant,
        store: MailStore,
        selected: Message?
    ) -> AssistantConversation {
        AssistantConversation(
            scope: .email,
            context: .init(subject: "Caixa e agenda de hoje"),
            destination: .init(label: "Neste Mac", detail: "Nada sai deste Mac.", isLocal: true),
            engine: AssistantBridge.engine(
                using: spy,
                supportsDraftReply: true,
                mailContext: {
                    guard let selected else { return AssistantMailContext(workspace: store) }
                    return AssistantMailContext(message: selected)
                }
            )
        )
    }

    /// O centro do botão "Gerar briefing" no recorte de 1200×820.
    ///
    /// O mockup o encosta no topo da coluna direita do cabeçalho
    /// (`.head { align-items: flex-start }`), a 22 do topo e 22 da direita,
    /// com 28 de altura — o centro fica em y = 22 + 14.
    private static let ctaPoint = (x: CGFloat(1_117), y: CGFloat(36))
    private static let dashboardSize = CGSize(width: 1_200, height: 820)

    /// Uma conversa com briefing pronto, sem motor: a faixa do §2.2 aparece
    /// sem ninguém falar com provedor nenhum.
    private func briefedConversation(_ text: String) -> AssistantConversation {
        AssistantConversation(
            scope: .workspace,
            context: .init(subject: "Caixa e agenda de hoje"),
            destination: .unconfigured,
            engine: .unavailable,
            debugState: AssistantPanelDebugState(briefingText: text)
        )
    }

    /// Uma conversa com transcript pronto, também sem motor.
    private func transcriptConversation() -> AssistantConversation {
        AssistantConversation(
            scope: .workspace,
            context: .init(subject: "Caixa e agenda de hoje"),
            destination: .unconfigured,
            engine: .unavailable,
            debugState: AssistantPanelDebugState(messages: [
                .init(speaker: .user, text: "O que a Marina precisa de mim para fechar o contrato?"),
                .init(
                    speaker: .assistant,
                    text: """
                        Marina revisou as cláusulas 4 e 7 com o jurídico; a única \
                        pendência é o escopo de suporte.

                        - Confirmar a call de quinta às 15h
                        - Levar a redação do SLA
                        """
                ),
            ])
        )
    }

    /// Os quatro estados do mockup (`cheio`, `vazio`, `com briefing`, `com
    /// transcript`). Os PNGs saem com `UNI_RENDER_DIR` para a conferência
    /// humana ao lado do mockup.
    @Test("os quatro estados do mockup desenham no claro e no escuro")
    func rendersTheFourStatesInBothThemes() async throws {
        let cheio = MailStore(source: InMemoryMailSource.fixtures)
        await cheio.load()
        let vazio = MailStore(
            source: InMemoryMailSource(accounts: [], messages: [], agenda: [])
        )
        await vazio.load()

        let estados: [(String, MailStore, AssistantConversation)] = [
            ("cheio", cheio, inertConversation()),
            ("vazio", vazio, inertConversation(scope: .workspace)),
            ("briefing", cheio, briefedConversation(
                """
                Dois emails pedem decisão hoje: Marina Duarte quer fechar o \
                contrato na quinta (09:42) e o formulário do site trouxe um lead \
                de consultoria para 40 pessoas. Sua tarde tem Revisão do contrato \
                às 14:00. A NF de agosto vence 05/09 — pode esperar até amanhã.
                """
            )),
            ("transcript", cheio, transcriptConversation()),
        ]

        // `okami` e `tinta` são o que a §2.6 exige; `noite` e `linho` entram
        // porque um escuro só e um claro só já esconderam defeito de degrau
        // de superfície neste app.
        for theme in [Theme.okami, Theme.tinta, Theme.noite, Theme.linho] {
            for (nome, store, conversation) in estados {
                let image = try #require(Render.snapshot(
                    DashboardScreen(
                        store: store,
                        now: Fixtures.nowMinute,
                        today: Fixtures.today,
                        conversation: conversation
                    )
                    .environment(ThemeStore()),
                    named: "\(theme.id)-\(nome)",
                    size: Self.dashboardSize,
                    theme: theme
                ), "\(theme.id)/\(nome) não desenhou")
                #expect(image.pixelsWide == 1_200)
                #expect(image.pixelsHigh == 820)
                // O fundo é `paper`, e não um cartão flutuante sobre ele.
                #expect(
                    image.pixels(matching: theme.paper, tolerance: 0.01) > 20_000,
                    "\(theme.id)/\(nome) perdeu o fundo da tela"
                )
            }
        }
    }

    /// A linha escreve o motivo **de verdade** — as seis razões, não o
    /// "Alta/Média" que o `rankPill` colapsava.
    @Test("cada linha de prioridade escreve a razão da fixture")
    func priorityRowShowsTheRealReason() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let focus = store.dashboardFocus(nowMinute: Fixtures.nowMinute)

        #expect(focus.mail.map(\.reason) == [.lead, .needsReply, .needsReply, .deadline, .unread])
        let primeiro = try #require(focus.mail.first)
        #expect(primeiro.reason.label == "Lead")
        #expect(
            DashboardMetrics.rowAccessibilityLabel(
                sender: primeiro.message.listHeadline,
                subject: primeiro.message.subject,
                reason: primeiro.reason
            ).contains("Lead")
        )

        // E o desenho muda com a razão: dois recortes iguais em tudo menos no
        // motivo da primeira linha não podem sair com o mesmo pixel.
        func bitmap(_ reason: DashboardFocus.Reason) throws -> NSBitmapImageRep {
            try #require(Render.bitmap(
                DashboardPriorityRow(
                    item: .init(message: primeiro.message, reason: reason),
                    tint: Theme.tinta.accent.color,
                    isUnread: true,
                    isSelected: false,
                    showsActions: false,
                    today: Fixtures.today
                )
                .frame(width: 500),
                size: CGSize(width: 500, height: 90),
                theme: .tinta
            ))
        }
        #expect(try bitmap(.lead).pixelsDiffering(from: try bitmap(.deadline)) > 100)
        #expect(try bitmap(.unread).pixelsDiffering(from: try bitmap(.today)) > 20)
    }

    /// "+ N na Caixa →" aponta para o que ficou fora do teto de sete. Com
    /// zero de fora, o rodapé some — um ponteiro para lugar nenhum é pior do
    /// que nenhum ponteiro.
    @Test("o rodapé aparece com 4 de fora e some com 0")
    func omittedFooterFollowsTheCount() async throws {
        func store(_ count: Int) async -> MailStore {
            let mensagens = (1...count).map { i in
                Message(
                    id: "m\(i)",
                    accountID: Fixtures.accounts[0].id,
                    from: Contact(name: "Quem \(i)", address: "quem\(i)@exemplo.com"),
                    receivedAt: Fixtures.today.addingTimeInterval(TimeInterval(-i * 60)),
                    subject: "Assunto \(i)",
                    snippet: "trecho \(i)",
                    body: [],
                    tags: [UNICore.Tag(name: "Precisa resposta")],
                    bucket: .today,
                    isRead: false,
                    summary: nil,
                    detectedEvent: nil
                )
            }
            let s = MailStore(source: InMemoryMailSource(
                accounts: Fixtures.accounts, messages: mensagens, agenda: []
            ))
            await s.load()
            return s
        }

        let onze = await store(11)
        let sete = await store(7)
        #expect(onze.dashboardFocus(nowMinute: Fixtures.nowMinute).omittedMailCount == 4)
        #expect(sete.dashboardFocus(nowMinute: Fixtures.nowMinute).omittedMailCount == 0)
        #expect(DashboardMetrics.omittedFooterLabel(4) == "+ 4 na Caixa →")
        #expect(DashboardMetrics.omittedFooterLabel(0) == nil)

        func bitmap(_ s: MailStore) throws -> NSBitmapImageRep {
            try #require(Render.bitmap(
                DashboardScreen(
                    store: s,
                    now: Fixtures.nowMinute,
                    today: Fixtures.today,
                    conversation: inertConversation(scope: .workspace)
                )
                .environment(ThemeStore()),
                size: Self.dashboardSize,
                theme: .tinta
            ))
        }
        // As sete linhas de cima são idênticas; o que difere é o rodapé.
        #expect(try bitmap(onze).pixelsDiffering(from: try bitmap(sete)) > 100)
    }

    /// As ações rápidas da §2.4 saem pela **mesma** porta da Caixa: um
    /// `ContextCommand`, que quem hospeda entrega à fila transacional com
    /// desfazer. O clique é sintético de verdade, como o do CTA.
    @Test("Arquivar manda .archived e Depois manda .later")
    func rowActionsRouteThroughContextCommand() async throws {
        // A linha do topo, no recorte de 1200×820: o cabeçalho ocupa 22 + a
        // caps + a saudação + 16, o rótulo PRIORIDADES mais 7, e a primeira
        // linha começa logo abaixo da hairline de topo da lista.
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let alvoID = try #require(
            store.dashboardFocus(nowMinute: Fixtures.nowMinute).mail.first
        ).id

        func clicou(_ x: CGFloat) -> [ContextCommand] {
            let espiao = CommandSpy()
            CliqueDeEnsaio.em(
                DashboardScreen(
                    store: store,
                    now: Fixtures.nowMinute,
                    today: Fixtures.today,
                    conversation: inertConversation(),
                    onCommand: { espiao.commands.append($0) },
                    debugHoveredMailID: alvoID
                )
                .environment(ThemeStore()),
                size: Self.dashboardSize,
                aY: Self.firstRowActionY,
                x: x
            )
            return espiao.commands
        }

        #expect(clicou(Self.archiveActionX) == [.move(messageID: alvoID, to: .archived)])
        #expect(clicou(Self.laterActionX) == [.move(messageID: alvoID, to: .later)])
    }

    /// O centro vertical da primeira linha de prioridade e o centro
    /// horizontal dos botões "Arquivar" e "Depois" nela, no recorte de
    /// 1200×820. Medidos no harness — ver `DashboardMockupParityTests`.
    private static let firstRowActionY: CGFloat = 153
    private static let archiveActionX: CGFloat = 746
    private static let laterActionX: CGFloat = 816

    @Test("a pergunta do briefing é a fixa da conversa, não uma cópia do dashboard")
    func briefingQuestionBelongsToTheConversation() {
        #expect(
            AssistantConversation.briefingQuestion == """
                Faça um briefing do meu dia em até 120 palavras: o que exige \
                resposta hoje, os compromissos de hoje em ordem, e o que pode \
                esperar. Cite remetentes e horários.
                """
        )
    }

    @Test("clicar o email abre a leitura por cima, sem trocar de aba")
    func rendersMailSheetOverDashboard() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let id = try #require(store.messages.first?.id)
        let reading = Binding<String?>.constant(id)
        let image = try #require(Render.snapshot(
            DashboardScreen(
                store: store,
                now: Fixtures.nowMinute,
                today: Fixtures.today,
                conversation: inertConversation(),
                readingMailID: reading
            )
            .environment(ThemeStore()),
            named: "dashboard-leitura",
            size: CGSize(width: 1_200, height: 820),
            theme: .okami
        ))
        #expect(image.pixelsWide == 1_200)
        #expect(image.pixelsHigh == 820)
    }

    @Test("\"Gerar rascunho\" chama draftReply(), não ask()")
    func draftButtonUsesDraftReply() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let spy = DashboardSpyAssistant()
        let mail = try #require(store.dashboardFocus(nowMinute: Fixtures.nowMinute).mail.first)
        let conversation = spiedConversation(spy, mail: mail.message)
        conversation.draftReply()
        await conversation.waitForIdle()

        #expect(spy.transforms.map(\.action) == [.draftReply])
        #expect(spy.answers.isEmpty)
        #expect(conversation.messages.last?.kind == .draft)
    }

    @Test("com email selecionado o CTA rascunha, não pergunta")
    func draftButtonClickReachesDraftReply() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let spy = DashboardSpyAssistant()
        let mail = try #require(store.dashboardFocus(nowMinute: Fixtures.nowMinute).mail.first)
        let conversation = dashboardConversation(spy, store: store, selected: mail.message)

        CliqueDeEnsaio.em(
            DashboardScreen(
                store: store,
                now: Fixtures.nowMinute,
                today: Fixtures.today,
                conversation: conversation,
                selectedMailID: .constant(mail.id)
            )
            .environment(ThemeStore()),
            size: Self.dashboardSize,
            aY: Self.ctaPoint.y,
            x: Self.ctaPoint.x
        )
        await conversation.waitForIdle()

        #expect(spy.transforms.map(\.action) == [.draftReply])
        #expect(spy.answers.isEmpty)
    }

    @Test("sem email selecionado o CTA pede briefing, e nunca rascunho")
    func ctaWithoutSelectionAsksForBriefing() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let spy = DashboardSpyAssistant()
        let conversation = dashboardConversation(spy, store: store, selected: nil)

        CliqueDeEnsaio.em(
            DashboardScreen(
                store: store,
                now: Fixtures.nowMinute,
                today: Fixtures.today,
                conversation: conversation
            )
            .environment(ThemeStore()),
            size: Self.dashboardSize,
            aY: Self.ctaPoint.y,
            x: Self.ctaPoint.x
        )
        await conversation.waitForIdle()

        // Briefing sai por `answer`, com a pergunta fixa da §2.5, e o
        // contexto é o ambiente — não um email que ninguém escolheu.
        #expect(spy.transforms.isEmpty)
        #expect(spy.answers.count == 1)
        #expect(conversation.briefingText == "resposta")
        #expect(conversation.messages.isEmpty)
        #expect(conversation.failure == nil)
        if case .workspace = try #require(spy.answers.first?.mailContext) {} else {
            Issue.record("O briefing pediu contexto de email sem email selecionado")
        }
    }

    @Test("o rótulo do CTA segue a seleção, e não o topo da lista")
    func ctaLabelFollowsSelection() {
        // A regra mora em `DashboardCTA`, fora da `View`. Ver
        // `DashboardMetricsTests` para o caso nonisolated.
        #expect(DashboardCTA.draftsReply(canDraftReply: true, hasSelectedMail: true))
        #expect(!DashboardCTA.draftsReply(canDraftReply: true, hasSelectedMail: false))
        #expect(!DashboardCTA.draftsReply(canDraftReply: false, hasSelectedMail: true))
        #expect(DashboardCTA.title(draftsReply: true) == "Gerar rascunho")
        #expect(DashboardCTA.title(draftsReply: false) == "Gerar briefing")
    }

    @Test("rascunho no transcript sai literal, sem Markdown")
    func draftTurnIsNotRenderedAsMarkdown() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let text = "Oi Marina,\n\n**Fechado** para terça.\n\n- item um\n- item dois"

        func bitmap(kind: AssistantTurnKind) throws -> NSBitmapImageRep {
            let conversation = AssistantConversation(
                scope: .email,
                context: .init(subject: "Revisão"),
                destination: .unconfigured,
                engine: .unavailable,
                debugState: AssistantPanelDebugState(
                    messages: [.init(speaker: .assistant, text: text, kind: kind)]
                )
            )
            return try #require(Render.bitmap(
                DashboardScreen(
                    store: store,
                    now: Fixtures.nowMinute,
                    today: Fixtures.today,
                    conversation: conversation
                )
                .environment(ThemeStore()),
                size: Self.dashboardSize,
                theme: .okami
            ))
        }

        // O mesmo texto como `.message` passa pelo Markdown: os asteriscos
        // somem e a lista ganha marcador. Como `.draft` fica literal.
        #expect(
            try bitmap(kind: .draft).pixelsDiffering(from: try bitmap(kind: .message)) > 200
        )
    }

    @Test("o dashboard não tem mais máquina de estado própria")
    func dashboardHasNoOwnStateMachine() throws {
        let source = try Self.dashboardSource()
        #expect(!source.contains("private func run("))
        #expect(!source.contains("private func runDraft("))
        #expect(!source.contains("private func runSuggestion("))
        #expect(!source.contains("@State private var loading"))
        #expect(!source.contains("@State private var errorMessage"))
    }

    /// O que a §2.2 manda **remover**. Um caso de fonte porque é isso que a
    /// lista pede: nenhum destes deixa rastro em pixel que dê para afirmar
    /// sozinho, e o que não se afirma volta na próxima edição.
    @Test("o cartão flutuante, os tiles e as cores literais sumiram")
    func removedDecorations() throws {
        let source = try Self.dashboardSource()
        for proibido in [
            "metricTile", "betaBadge", "private var robot", "func board<",
            "Color.black.opacity", "cornerRadius: 20", "cornerRadius: 14",
            "theme.info.color.opacity",
            "Ver todas", "👋",
        ] {
            #expect(!source.contains(proibido), "\(proibido) continua em DashboardScreen.swift")
        }
        // Os `Spacer(minLength: 0)` que enchiam os cartões sumiram. Sobra
        // **um**, e ele é o `.flexpad` do mockup: a folga entre a lista de
        // prioridades e o assistente colado no rodapé.
        #expect(source.components(separatedBy: "Spacer(minLength: 0)").count - 1 == 1)
    }

    static func dashboardSource() throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/UNIShell/Inbox/DashboardScreen.swift"),
            encoding: .utf8
        )
    }
}

/// A régua do mockup, no molde dos testes de hairline: os números que
/// `design/07-dashboard.html` fixa, medidos no desenho de verdade.
@Suite("Dashboard · paridade com o mockup")
@MainActor
struct DashboardMockupParityTests {

    private static let size = CGSize(width: 1_200, height: 820)

    private func screen(_ store: MailStore) -> some View {
        DashboardScreen(
            store: store,
            now: Fixtures.nowMinute,
            today: Fixtures.today,
            conversation: AssistantConversation(
                scope: .workspace,
                context: .init(subject: "Caixa e agenda de hoje"),
                destination: .unconfigured,
                engine: .unavailable
            )
        )
        .environment(ThemeStore())
    }

    /// `.rail { width: 300px }` dentro de `.content { padding: 22px }`: numa
    /// janela de 1200, a coluna direita vai de 878 a 1177, e o que está de
    /// fora dela é `paper`.
    ///
    /// Medido em `okami` de propósito: no `tinta` deste app `paper` e
    /// `surface` são os dois branco puro (`Themes+Generated.swift`), e uma
    /// régua que não distingue as duas não mede nada.
    @Test("a coluna direita mede 300 e encosta no recuo de 22")
    func railIsThreeHundredWide() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let rep = try #require(Render.bitmap(screen(store), size: Self.size, theme: .okami))

        let inicio = Int(Self.size.width - DashboardMetrics.outerPadding - DashboardMetrics.railWidth)
        let fim = Int(Self.size.width - DashboardMetrics.outerPadding) - 1
        #expect(inicio == 878)
        #expect(fim == 1_177)

        func cor(_ x: Int) throws -> NSColor {
            try #require(rep.colorAt(x: x, y: 320)?.usingColorSpace(.sRGB))
        }
        func é(_ x: Int, _ token: TokenColor) throws -> Bool {
            let a = try cor(x)
            let b = try #require(token.nsColor.usingColorSpace(.sRGB))
            return abs(a.redComponent - b.redComponent) < 0.005
                && abs(a.greenComponent - b.greenComponent) < 0.005
                && abs(a.blueComponent - b.blueComponent) < 0.005
        }
        // A folga de 18 antes da coluna, e o recuo de 22 depois dela: `paper`
        // dos dois lados. Dentro, `surface`.
        #expect(try é(inicio - 4, Theme.okami.paper), "a folga de 18 antes da coluna sumiu")
        #expect(try é(inicio + 2, Theme.okami.surface), "a coluna direita não começa em 878")
        #expect(try é(fim - 2, Theme.okami.surface), "a coluna direita não termina em 1177")
        #expect(try é(fim + 4, Theme.okami.paper), "o recuo de 22 da direita sumiu")
    }

    /// `.transcript { max-height: 300px; overflow-y: auto }`: um transcript
    /// longo **não** pode empurrar a cápsula do campo. A régua é a própria
    /// propriedade que importa — dois recortes, um com duas linhas de
    /// resposta e outro com sessenta parágrafos, têm o mesmo rodapé pixel a
    /// pixel — e ela não depende de nenhum token ser distinguível no tema.
    @Test("o transcript para nos 300 e o campo continua no rodapé")
    func transcriptStopsAtThreeHundred() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()

        func recorte(_ resposta: String) throws -> NSBitmapImageRep {
            let conversation = AssistantConversation(
                scope: .workspace,
                context: .init(subject: "Caixa e agenda de hoje"),
                destination: .unconfigured,
                engine: .unavailable,
                debugState: AssistantPanelDebugState(messages: [
                    .init(speaker: .user, text: "Resuma o dia"),
                    .init(speaker: .assistant, text: resposta),
                ])
            )
            return try #require(Render.bitmap(
                DashboardScreen(
                    store: store,
                    now: Fixtures.nowMinute,
                    today: Fixtures.today,
                    conversation: conversation
                )
                .environment(ThemeStore()),
                size: Self.size,
                theme: .okami
            ))
        }

        let curto = try recorte("Duas linhas bastam.")
        let longo = try recorte(
            (1...60).map { "Parágrafo \($0) do transcript." }.joined(separator: "\n\n")
        )
        // O rodapé da coluna — cápsula do campo e rótulo do destino — é o
        // mesmo nos dois: 60 parágrafos rolam por dentro do painel.
        #expect(
            curto.pixelsDiffering(
                from: longo,
                inColumns: 0..<Int(Self.size.width),
                rows: 740..<Int(Self.size.height)
            ) == 0
        )
        #expect(DashboardMetrics.transcriptMaxHeight == 300)
    }
}
