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

/// A seleção e a leitura do dashboard, num lugar que um `Binding` alcança.
///
/// `Binding(get:set:)` guarda closures não isoladas, então a caixa não pode
/// ser `@MainActor`. Ela só é lida e escrita na `main` — o `CliqueDeEnsaio`
/// roda tudo lá — e por isso o `@unchecked` é honesto aqui.
private final class CaixaDeSelecao: @unchecked Sendable {
    var selecionado: String?
    var lendo: String?
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

    /// Uma conversa que já devolveu um rascunho, sem motor. É o estado
    /// `rascunho` do mockup: o turno `.draft` nasce dentro da prévia.
    private func draftedConversation() -> AssistantConversation {
        AssistantConversation(
            scope: .email,
            context: .init(subject: "Revisão do contrato"),
            destination: .unconfigured,
            engine: .unavailable,
            debugState: AssistantPanelDebugState(messages: [
                .init(
                    speaker: .assistant,
                    text: """
                        Oi Marina, fechado — SLA de 4 horas úteis funciona para \
                        nós. Confirmo a call de quinta às 15h e levo a redação \
                        final do SLA.

                        Abraço, Marcos
                        """,
                    kind: .draft
                ),
            ])
        )
    }

    /// Um store sem compromisso e sem pendência: o `agenda-vazia` do mockup.
    private func lojaDeDiaLivre() async -> MailStore {
        let store = MailStore(source: InMemoryMailSource(
            accounts: Fixtures.accounts,
            messages: Fixtures.messages,
            agenda: []
        ))
        await store.load()
        return store
    }

    /// Os cinco estados do mockup (`cheio`, `vazio`, `rascunho`,
    /// `assistente`, `agenda-vazia`). Os PNGs saem com `UNI_RENDER_DIR` para
    /// a conferência humana ao lado do mockup.
    @Test("os cinco estados do mockup desenham no claro e no escuro")
    func rendersTheFiveStatesInBothThemes() async throws {
        let cheio = MailStore(source: InMemoryMailSource.fixtures)
        await cheio.load()
        let vazio = MailStore(
            source: InMemoryMailSource(accounts: [], messages: [], agenda: [])
        )
        await vazio.load()
        let diaLivre = await lojaDeDiaLivre()

        let estados: [(String, MailStore, AssistantConversation)] = [
            ("cheio", cheio, inertConversation()),
            ("vazio", vazio, inertConversation(scope: .workspace)),
            ("rascunho", cheio, draftedConversation()),
            ("assistente", cheio, transcriptConversation()),
            ("agenda-vazia", diaLivre, inertConversation()),
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

    /// As ações da prévia saem pela **mesma** porta da Caixa: um
    /// `ContextCommand`, que quem hospeda entrega à fila transacional com
    /// desfazer. O clique é sintético de verdade.
    ///
    /// Elas moram na prévia, e não mais no hover da linha: a queixa era que
    /// "não tem quase nada" na tela e que clicar abria modal. Agora clicar
    /// seleciona, e as quatro ações do email ficam à vista na coluna do meio.
    @Test("Arquivar manda .archived e Depois manda .later, da prévia")
    func previewActionsRouteThroughContextCommand() async throws {
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
                    selectedMailID: .constant(alvoID),
                    onCommand: { espiao.commands.append($0) }
                )
                .environment(ThemeStore()),
                size: Self.dashboardSize,
                aY: Self.previewActionsY,
                x: x
            )
            return espiao.commands
        }

        #expect(clicou(Self.archiveActionX) == [.move(messageID: alvoID, to: .archived)])
        #expect(clicou(Self.laterActionX) == [.move(messageID: alvoID, to: .later)])
    }

    /// O centro da fileira de ações da prévia e o centro horizontal de cada
    /// botão nela, no recorte de 1200×820. A fileira mora no **rodapé** da
    /// coluna do meio — ancorada lá para não dançar conforme o corpo do email
    /// cresce ou encolhe —, e por isso o Y é 784 e não a altura do texto.
    /// Medidos no harness — ver `DashboardMockupParityTests`.
    private static let previewActionsY: CGFloat = 784
    private static let draftActionX: CGFloat = 554
    private static let archiveActionX: CGFloat = 744
    private static let laterActionX: CGFloat = 820
    private func tela(_ store: MailStore, caixa: CaixaDeSelecao) -> some View {
        DashboardScreen(
            store: store,
            now: Fixtures.nowMinute,
            today: Fixtures.today,
            conversation: inertConversation(),
            selectedMailID: Binding(
                get: { caixa.selecionado }, set: { caixa.selecionado = $0 }
            ),
            readingMailID: Binding(get: { caixa.lendo }, set: { caixa.lendo = $0 })
        )
        .environment(ThemeStore())
    }

    /// O centro vertical da segunda linha de prioridade, para o clique que
    /// seleciona.
    private static let secondRowY: CGFloat = 269
    private static let rowX: CGFloat = 200

    /// **A queixa mais dura do dono**: "ao clicar ele já abre o modal de uma
    /// vez". Agora não abre. Um clique seleciona, e a folha do leitor
    /// continua fechada.
    @Test("um clique seleciona a linha e não abre a folha")
    func clickSelectsWithoutOpening() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let focus = store.dashboardFocus(nowMinute: Fixtures.nowMinute)
        let segundo = try #require(focus.mail.dropFirst().first).id

        let caixa = CaixaDeSelecao()
        CliqueDeEnsaio.em(
            tela(store, caixa: caixa),
            size: Self.dashboardSize,
            aY: Self.secondRowY,
            x: Self.rowX
        )

        #expect(caixa.selecionado == segundo, "o clique não selecionou a segunda linha")
        #expect(caixa.lendo == nil, "o clique abriu a folha do leitor")
    }

    /// Abrir de verdade é duplo clique — e ⏎, que se prova em
    /// `DashboardKeys`.
    @Test("o duplo clique abre a folha do leitor")
    func doubleClickOpensTheSheet() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let focus = store.dashboardFocus(nowMinute: Fixtures.nowMinute)
        let segundo = try #require(focus.mail.dropFirst().first).id

        let caixa = CaixaDeSelecao()
        CliqueDeEnsaio.em(
            tela(store, caixa: caixa),
            size: Self.dashboardSize,
            aY: Self.secondRowY,
            x: Self.rowX,
            cliques: 2
        )

        #expect(caixa.selecionado == segundo)
        #expect(caixa.lendo == segundo, "o duplo clique não abriu a folha")
    }

    /// A outra metade de "abrir": o ⏎.
    ///
    /// A decisão mora em `DashboardKeys`, fora da `View`. A entrega da tecla
    /// é do `BareKeyMonitor`, e sintetizar tecla num processo de teste
    /// derruba o laço da `main` — a nota está no cabeçalho do
    /// `CliqueDeEnsaio`.
    @Test("⏎ abre o selecionado, e só ele")
    func enterOpensTheSelection() {
        #expect(
            DashboardKeys.opens(
                key: .enter, selectedID: "m1", readingID: nil, exists: true
            ) == "m1"
        )
        // Sem seleção não há o que abrir.
        #expect(
            DashboardKeys.opens(
                key: .enter, selectedID: nil, readingID: nil, exists: false
            ) == nil
        )
        // A folha já aberta fica com o ⏎ (é o Enter de dentro do leitor).
        #expect(
            DashboardKeys.opens(
                key: .enter, selectedID: "m1", readingID: "m1", exists: true
            ) == nil
        )
        // Nenhuma outra tecla abre nada.
        for key in [BareKey.delete, .up, .down, .escape] {
            #expect(
                DashboardKeys.opens(
                    key: key, selectedID: "m1", readingID: nil, exists: true
                ) == nil
            )
        }
    }

    /// "Gerar resposta" é o botão primário da prévia, e ele chega em
    /// `draftReply()` — nunca em `answer`. O rascunho aparece **dentro** da
    /// prévia, colado no email, e não como bloco solto no meio da tela.
    @Test("\"Gerar resposta\" da prévia chega em draftReply e desenha na prévia")
    func previewDraftButtonReachesDraftReply() async throws {
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
            aY: Self.previewActionsY,
            x: Self.draftActionX
        )
        await conversation.waitForIdle()

        #expect(spy.transforms.map(\.action) == [.draftReply])
        #expect(spy.answers.isEmpty, "o botão da prévia passou por answer()")
        #expect(conversation.messages.last?.kind == .draft)

        // E o rascunho sai **na prévia**: as colunas da coluna do meio mudam,
        // as da lista não. A lista é 22..466 no recorte de 1200.
        func recorte(_ conversa: AssistantConversation) throws -> NSBitmapImageRep {
            try #require(Render.bitmap(
                DashboardScreen(
                    store: store,
                    now: Fixtures.nowMinute,
                    today: Fixtures.today,
                    conversation: conversa,
                    selectedMailID: .constant(mail.id)
                )
                .environment(ThemeStore()),
                size: Self.dashboardSize,
                theme: .okami
            ))
        }
        let semRascunho = try recorte(inertConversation())
        let comRascunho = try recorte(draftedConversation())
        #expect(
            comRascunho.pixelsDiffering(from: semRascunho, inColumns: 498..<862) > 500,
            "o rascunho não apareceu dentro da prévia"
        )
        #expect(
            comRascunho.pixelsDiffering(from: semRascunho, inColumns: 22..<466) == 0,
            "o rascunho vazou para a coluna da lista"
        )
    }

    /// A faixa HOJE conta o que a triagem achou, e o excedente diz o que ela
    /// descartou. Os dois números são diferentes de propósito.
    @Test("a faixa HOJE conta certo e escreve o excedente")
    func todayBandCountsWhatTheTriageFound() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let focus = store.dashboardFocus(nowMinute: Fixtures.nowMinute)

        let linhas = DashboardToday.lines(focus, now: Fixtures.today)
        let respostas = focus.mail.filter { $0.reason == .needsReply }.count
        #expect(respostas == 2)
        #expect(linhas.first?.text == "2 pedem resposta")
        #expect(linhas.first?.tone == .warning)
        #expect(linhas.first?.messageID != nil, "a linha da faixa não aponta para mensagem")
        #expect(linhas.contains { $0.text.hasPrefix("Prazo: ") })
        #expect(linhas.contains { $0.text.hasPrefix("1 lead novo — ") })
        #expect(linhas.allSatisfy { $0.messageID != nil })

        #expect(focus.discardedMailCount == 2)
        #expect(
            DashboardToday.restLabel(focus.discardedMailCount)
                == "2 fora da lista · newsletters e avisos"
        )
        #expect(DashboardToday.restLabel(0) == nil)

        // Caixa vazia: uma linha só, sem ponteiro para lugar nenhum.
        let vazio = DashboardFocus(
            mail: [], meetings: [], pending: [],
            omittedMailCount: 0, omittedMeetingCount: 0, nextUpLabel: "",
            discardedMailCount: 9
        )
        let semNada = DashboardToday.lines(vazio, now: Fixtures.today)
        #expect(semNada.count == 1)
        #expect(semNada[0].text == "Nada precisa de você — 9 mensagens triadas para a Caixa.")
        #expect(semNada[0].messageID == nil)
    }

    /// O bloco Contexto mostra o que o app **já sabe** — e some quando não
    /// sabe nada, em vez de desenhar um rótulo sobre o vazio.
    @Test("o Contexto sai do compromisso, da pendência e da conversa anterior")
    func previewContextComesFromWhatTheAppKnows() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let marina = try #require(
            store.messages.first { $0.from.name.contains("Marina") }
        )
        let linhas = DashboardPreviewContext.lines(
            for: marina,
            agenda: store.visibleAgenda,
            pending: store.pendingItems,
            messages: store.messages
        )
        #expect(linhas.contains { $0.text.contains("1:1 Marina Duarte") })
        #expect(linhas.contains { $0.text.hasPrefix("Pendência: ") })

        // Ninguém conhecido: nada é inventado.
        let estranho = Message(
            id: "zz", accountID: Fixtures.accounts[0].id,
            from: Contact(name: "Xyzzy Qwerty", address: "zz@exemplo.com"),
            receivedAt: Fixtures.today, subject: "Oi", snippet: "oi", body: ["oi"],
            tags: [], bucket: .today, isRead: false, summary: nil, detectedEvent: nil
        )
        #expect(
            DashboardPreviewContext.lines(
                for: estranho, agenda: store.visibleAgenda,
                pending: store.pendingItems, messages: store.messages
            ).isEmpty
        )
    }

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
            // O botão que gerava briefing sob demanda. A faixa HOJE o
            // substituiu, e ela já está lá quando a tela abre.
            "Gerar briefing", "ctaButton",
        ] {
            #expect(!source.contains(proibido), "\(proibido) continua em DashboardScreen.swift")
        }
        // Os `Spacer(minLength: 0)` que enchiam os cartões sumiram. Sobram
        // **três**, e todos carregam decisão de layout: o par que decide se a
        // folga fica antes ou depois do assistente — com poucas prioridades o
        // campo cola na lista, com muitas ele desce para o rodapé, que é o
        // vazio de 400pt que o dono reclamou — e o da coluna de dia livre.
        #expect(source.components(separatedBy: "Spacer(minLength: 0)").count - 1 == 3)
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

    /// A trilha nunca entrega meio cartão às PENDÊNCIAS, em nenhum estado que
    /// tenha trilha.
    ///
    /// A régua é a mesma dos testes de hairline: acha-se o fio `line2` que
    /// abre a seção de PENDÊNCIAS e conferem-se as seis faixas logo acima
    /// dele. Todo cartão da trilha carrega 10pt de folga embaixo — se a borda
    /// partisse um, ali estaria a cor da conta em vez do fundo da coluna.
    @Test("a coluna direita não corta cartão em nenhum estado com trilha")
    func railCutsOnCardBoundaryInEveryState() async throws {
        let cheio = MailStore(source: InMemoryMailSource.fixtures)
        await cheio.load()

        // O estado `vazio` e o `agenda-vazia` ficam de fora **porque não têm
        // trilha**: sem compromisso e sem pendência a coluna encolhe para 168
        // e vira o recado "Dia livre". Isso tem caso próprio abaixo.
        let estados: [(String, MailStore, AssistantConversation)] = [
            ("cheio", cheio, conversa()),
            ("rascunho", cheio, conversa(draft: true)),
            ("assistente", cheio, conversa(transcript: true)),
        ]

        let fundo = try #require(Theme.okami.surface.nsColor.usingColorSpace(.sRGB))
        let fio = try #require(Theme.okami.line2.nsColor.usingColorSpace(.sRGB))

        for (nome, store, conversation) in estados {
            let rep = try #require(Render.bitmap(
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

            func combina(_ c: NSColor?, _ alvo: NSColor, _ folga: Double) -> Bool {
                guard let c = c?.usingColorSpace(.sRGB) else { return false }
                return abs(c.redComponent - alvo.redComponent) <= folga
                    && abs(c.greenComponent - alvo.greenComponent) <= folga
                    && abs(c.blueComponent - alvo.blueComponent) <= folga
            }

            // O fio que abre as PENDÊNCIAS: a faixa mais baixa que atravessa a
            // coluna inteira em `line2`.
            let colunas = 882..<1_170
            var topoDasPendencias: Int?
            for y in stride(from: Int(Self.size.height) - 30, to: 200, by: -1) {
                let iguais = colunas.filter { combina(rep.colorAt(x: $0, y: y), fio, 0.01) }.count
                if iguais > colunas.count - 10 {
                    topoDasPendencias = y
                    break
                }
            }
            let topo = try #require(topoDasPendencias, "\(nome): não achei o fio das PENDÊNCIAS")

            var sujas = 0
            for y in (topo - 6)..<topo {
                for x in colunas where !combina(rep.colorAt(x: x, y: y), fundo, 0.02) {
                    sujas += 1
                }
            }
            #expect(sujas == 0, "\(nome): a trilha entregou \(sujas) pixels de cartão ao fio")
        }
    }

    private func conversa(
        transcript: Bool = false, draft: Bool = false
    ) -> AssistantConversation {
        var turnos: [AssistantMessage] = []
        if transcript {
            turnos = [
                .init(speaker: .user, text: "Resuma o dia"),
                .init(speaker: .assistant, text: "Marina espera o SLA."),
            ]
        }
        if draft {
            turnos = [
                .init(speaker: .assistant, text: "Oi Marina, fechado.", kind: .draft),
            ]
        }
        return AssistantConversation(
            scope: .workspace,
            context: .init(subject: "Caixa e agenda de hoje"),
            destination: .unconfigured,
            engine: .unavailable,
            debugState: AssistantPanelDebugState(messages: turnos)
        )
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
        #expect(DashboardMetrics.transcriptMaxHeight == 280)
    }
}
