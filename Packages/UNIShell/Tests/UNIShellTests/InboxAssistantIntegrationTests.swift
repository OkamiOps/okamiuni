import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// Conversa de ensaio: motor com as duas rotas separadas, sem rede e sem
/// FoundationModels. É por ela que a IA do leitor passa.
@MainActor
private func rehearsalConversation(
    subject: String = "Ensaio",
    sender: String? = nil,
    answer: @escaping (AssistantRequest) async throws -> String = { _ in "" },
    draftReply: @escaping (AssistantRequest) async throws -> String = { _ in "" }
) -> AssistantConversation {
    AssistantConversation(
        scope: .email,
        context: .init(subject: subject, sender: sender),
        destination: .unconfigured,
        engine: AssistantEngine(
            supportsDraftReply: true,
            answer: answer,
            draftReply: draftReply
        )
    )
}

@Suite("Assistente integrado ao leitor")
@MainActor
struct InboxAssistantIntegrationTests {
    /// A mesma garantia de sempre — a porta da IA é um controle de verdade e
    /// respeita indisponibilidade —, agora na pastilha ✦ IA do desenho
    /// `IA-Tinta`, que é a porta única dos 28 temas. O ícone redondo que vivia
    /// na barra de triagem dos temas opacos saiu: duas portas para a mesma
    /// coisa divergiam no primeiro conserto.
    @Test("a pastilha ✦ IA abre a IA e respeita indisponibilidade", arguments: [
        (IntelligencePresentation.onThisMac, 1),
        (IntelligencePresentation.modelNotReady, 0),
    ])
    func readerButtonIsAnAction(
        presentation: IntelligencePresentation, esperado: Int
    ) async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        store.select(bucket: .all)
        store.select(message: "m1")
        var abriu = 0
        CliqueDeEnsaio.em(
            ReaderPane(
                store: store,
                intelligence: { _ in "ok" },
                intelligencePresentation: presentation,
                makeAssistantConversation: { _ in rehearsalConversation() },
                onEmailAssistantOpenChange: { if $0 { abriu += 1 } }
            ),
            size: CGSize(width: 760, height: 700),
            // A barra de ferramentas do leitor tem 46 de altura e a pastilha
            // mora na ponta esquerda dela, depois dos 14 de recuo: é o que o
            // desenho escreve, e é onde o clique tem de cair.
            aY: 23, x: 50,
            theme: .vidro
        )
        #expect(abriu == esperado)
    }

    @Test("marcador aplicado vira uma pastilha visível no leitor")
    func appliedLabelHasVisibleFeedback() {
        let message = Message(
            id: "gmail:g:42",
            accountID: "gmail",
            from: Contact(name: "GitHub", address: "noreply@github.com"),
            receivedAt: Fixtures.today,
            subject: "Payment receipt",
            snippet: "Receipt",
            body: [],
            tags: [],
            bucket: .today,
            isRead: true,
            summary: nil,
            detectedEvent: nil,
            folderIDs: ["gmail/INBOX", "gmail/Label_42"]
        )
        let inbox = MailFolder(
            id: "gmail/INBOX",
            accountID: "gmail",
            serverName: "INBOX",
            displayName: "Entrada",
            role: .inbox
        )
        let marker = MailFolder(
            id: "gmail/Label_42",
            accountID: "gmail",
            serverName: "Label_42",
            displayName: "00_Novos/Compras_Recibos",
            role: .other
        )
        let foreign = MailFolder(
            id: "other/Label_42",
            accountID: "other",
            serverName: "Label_42",
            displayName: "Outra conta",
            role: .other
        )

        let visible = ReaderPane.appliedMarkers(
            for: message,
            in: [inbox, marker, foreign]
        )

        #expect(visible == [marker])
        #expect(ReaderPane.markerChipLabel(marker.displayName) == "Compras_Recibos")
    }

    @Test("pastilha do marcador renderiza no cabeçalho do email")
    func appliedLabelRendersInReaderHeader() async throws {
        let account = Account(
            id: "gmail",
            address: "marcos@example.com",
            displayName: "Marcos",
            provider: .gmail,
            host: "GMAIL",
            tintLightHex: "#2F6FED",
            tintDarkHex: "#75A7FF"
        )
        let marker = MailFolder(
            id: "gmail/Label_42",
            accountID: "gmail",
            serverName: "Label_42",
            displayName: "00_Novos/Compras_Recibos",
            role: .other
        )
        let message = Message(
            id: "gmail:g:42",
            accountID: "gmail",
            from: Contact(name: "GitHub", address: "noreply@github.com"),
            receivedAt: Fixtures.today,
            subject: "Payment receipt",
            snippet: "Receipt",
            body: ["Your payment was received."],
            tags: [],
            bucket: .today,
            isRead: true,
            summary: nil,
            detectedEvent: nil
        )
        let plainStore = MailStore(source: MarkerMailSource(
            account: account,
            message: message,
            folders: [marker]
        ))
        let markedStore = MailStore(source: MarkerMailSource(
            account: account,
            message: message.withFolderIDs([marker.id]),
            folders: [marker]
        ))
        await plainStore.load()
        await markedStore.load()
        plainStore.select(message: message.id)
        markedStore.select(message: message.id)
        let size = CGSize(width: 760, height: 700)

        let plain = try #require(Render.bitmap(
            ReaderPane(store: plainStore), size: size, theme: .tinta
        ))
        let marked = try #require(Render.snapshot(
            ReaderPane(store: markedStore),
            named: "reader-applied-marker",
            size: size,
            theme: .tinta
        ))

        #expect(
            // A pastilha mudou de linha com o `Leitor5`: era a faixa de
            // procedência no alto do cabeçalho, e agora fica ao lado de quem
            // mandou — a linha do remetente, logo abaixo do assunto.
            marked.pixelsDiffering(
                from: plain,
                inColumns: 85..<480,
                rows: 80..<130
            ) > 200
        )
    }

    @Test("Gerar resposta do leitor usa o gerador do composer, não a pergunta analítica")
    func readerReplyUsesComposerGenerator() async throws {
        var generatedReplies = 0
        var analyticalQuestions = 0
        let conversation = rehearsalConversation(
            subject: "Website Revamp & SEO",
            sender: "Max",
            answer: { _ in
                analyticalQuestions += 1
                return "Análise"
            },
            draftReply: { _ in
                generatedReplies += 1
                return "Hi Max, thank you for the details."
            }
        )
        // **A garantia é a rota, não o pixel.** O que este caso guarda —
        // rascunho sai por `draftReply`, e `answer` não é tocado — é afirmado
        // pela rota, que é onde o defeito morava. E "Rascunhar resposta" não
        // tem pergunta analítica nenhuma: ela é `nil` em `ReaderAIAction`,
        // que é o que a manda pelo caminho do rascunho.
        #expect(ReaderAIAction.rascunhar.question == nil)
        #expect(ReaderAIAction.evento.question == nil)
        #expect(ReaderAIAction.resumir.question?.isEmpty == false)
        conversation.draftReply()
        await conversation.waitForIdle()

        #expect(generatedReplies == 1)
        #expect(analyticalQuestions == 0)
    }

    @Test("listas Markdown mantêm itens separados no mini-chat")
    func readerMarkdownPreservesRequestedStructure() {
        let blocks = AssistantMarkdownBlock.parse("""
        # Próximos passos

        - Confirmar a pauta com Produto
        - Responder ao cliente até segunda-feira

        1. Revisar o anexo
        2) Enviar a versão final
        """)

        #expect(blocks.map(\.kind) == [
            .heading("Próximos passos"),
            .bullet("Confirmar a pauta com Produto"),
            .bullet("Responder ao cliente até segunda-feira"),
            .numbered(marker: "1.", text: "Revisar o anexo"),
            .numbered(marker: "2)", text: "Enviar a versão final"),
        ])
    }

    /// **A direção Tinta tira o painel do caminho.**
    ///
    /// Os três casos que viviam aqui — painel por cima do corpo, por cima de
    /// um assunto de três linhas, por cima da divisória da pilha — eram
    /// variações de um defeito só: uma superfície da IA desenhada **sobre** o
    /// e-mail, que o `VStack` do cabeçalho às vezes ganhava. O desenho
    /// aprovado (`IA-Tinta.dc.html`) não tem essa superfície: o ✦ IA abre um
    /// menu (popover, fora da árvore do leitor) e o que a IA diz é escrito no
    /// próprio fluxo de leitura.
    ///
    /// A garantia dos três, então, virou esta, e vale para qualquer assunto e
    /// qualquer pilha: **com o menu aberto, a área de leitura sai idêntica.**
    /// Nada é coberto, nada é cortado por hairline nenhuma, e não há camada
    /// para o assunto disputar. Onde a tinta de fato aparece, e em que ordem,
    /// é o que `IAPresencaTintaRenderTests` mede contra o desenho.
    @Test(
        "o menu da IA não pinta nada por cima do e-mail",
        arguments: [(Theme.vidro, false), (Theme.vidro, true), (Theme.tinta, false)]
    )
    func readerInkNeverCoversTheEmail(tema: Theme, emPilha: Bool) async throws {
        let account = Account(
            id: "a", address: "conta@dominio.com", displayName: "Conta",
            provider: .imap, host: "host", tintLightHex: "#3E6FA8", tintDarkHex: "#7BA8D9"
        )
        // O assunto de três linhas do print do dono, que era o que disputava a
        // camada com o painel antigo.
        func msg(_ id: String, at segundos: TimeInterval) -> Message {
            Message(
                id: id, accountID: "a",
                from: Contact(name: "cursor[bot]", address: "notifications@github.com"),
                receivedAt: Date(timeIntervalSince1970: segundos),
                subject: "Re: [aitherion-labs/contion-app] Contion — workflow contábil "
                    + "agêntico (fiscal real, certificado, agentes, WhatsApp) (PR #2)",
                snippet: "pushed", body: ["commit"], tags: [], bucket: .today,
                isRead: true, summary: nil, detectedEvent: nil,
                threadKey: emPilha ? "t1" : nil
            )
        }
        let mensagens = emPilha
            ? [msg("c", at: 300), msg("a", at: 100)]
            : [msg("c", at: 300)]
        let store = MailStore(
            source: InMemoryMailSource(accounts: [account], messages: mensagens, agenda: [])
        )
        await store.load()
        store.select(bucket: .all)
        store.select(message: "c")
        let size = CGSize(width: 760, height: 700)
        let generator: ComposerIntelligenceGenerator = { _ in "ok" }

        func desenho(menuAberto: Bool) throws -> NSBitmapImageRep {
            try #require(Render.bitmap(
                ReaderPane(
                    store: store,
                    debugEmailAssistantOpen: menuAberto,
                    intelligence: generator,
                    makeAssistantConversation: { _ in rehearsalConversation() }
                ),
                size: size, theme: tema
            ))
        }

        let fechado = try desenho(menuAberto: false)
        let aberto = try desenho(menuAberto: true)

        // A pastilha acende em acento cheio: é a única coisa que muda.
        #expect(
            aberto.pixels(matching: tema.accent, tolerance: 0.03)
                > fechado.pixels(matching: tema.accent, tolerance: 0.03) + 200,
            "\(tema.id): o ✦ IA não deu sinal de que o menu abriu"
        )
        // E no e-mail, nada. Nem o assunto, nem a divisória, nem o corpo:
        // não há painel para cobrir nada disso.
        #expect(
            aberto.pixelsDiffering(from: fechado, inColumns: 0..<760, rows: 320..<700) == 0,
            "\(tema.id): alguma coisa da IA foi desenhada por cima do e-mail"
        )
    }

    @Test("painel abre sobre o email sem quebrar o shell")
    func openPanelRendersOffscreen() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let size = CGSize(width: 1_440, height: 858)
        let assistant = IntegrationAssistant()

        let closed = try #require(Render.snapshot(
            InboxScreen(store: store, textAssistant: assistant)
                .environment(ThemeStore()),
            named: "m5-inbox-assistant-closed",
            size: size,
            theme: .tinta
        ))
        let open = try #require(Render.snapshot(
            InboxScreen(
                store: store,
                textAssistant: assistant,
                debugAssistantOpen: true
            )
            .environment(ThemeStore()),
            named: "m5-inbox-assistant-open",
            size: size,
            theme: .tinta
        ))
        let selectedID = try #require(store.selectedMessageID)
        let emailActions = try #require(Render.snapshot(
            InboxScreen(
                store: store,
                textAssistant: assistant,
                debugAssistantOpen: true,
                debugAssistantScope: .email(selectedID)
            )
            .environment(ThemeStore()),
            named: "m5-inbox-assistant-email-actions",
            size: size,
            theme: .tinta
        ))

        #expect(closed.pixelsDiffering(from: open) > 20_000)
        #expect(open.pixelsDiffering(from: emailActions) > 2_000)
    }

    /// O caso inverso do que vivia aqui.
    ///
    /// Antes o painel da IA tinha de **atravessar** o `HStack` das três
    /// colunas, e este teste media esse atravessamento. Na direção Tinta não
    /// há painel: o menu é popover do AppKit e o resultado é escrito no fluxo,
    /// então o shell não precisa elevar nada — e a prova disso é que a tela
    /// inteira sai igual, tirando a pastilha acesa.
    @Test("o shell não precisa elevar nada para a IA do leitor")
    func readerInkNeedsNoShellLayer() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        store.select(bucket: .all)
        store.select(message: "m1")
        let assistant = IntegrationAssistant()
        let size = CGSize(width: 1_440, height: 858)

        // O harness já desenha sem movimento (ver `Render.bitmap`): com o fio
        // de tinta vivo, duas imagens do mesmo desenho nunca seriam iguais.
        let closed = try #require(Render.bitmap(
            InboxScreen(store: store, textAssistant: assistant)
                .environment(ThemeStore()),
            size: size,
            theme: .tinta
        ))
        let open = try #require(Render.snapshot(
            InboxScreen(
                store: store,
                textAssistant: assistant,
                debugAssistantOpen: false,
                debugReaderAssistantOpen: true
            )
            .environment(ThemeStore()),
            named: "reader-ink-menu-no-shell-layer",
            size: size,
            theme: .tinta
        ))

        // A pastilha acende: a tinta de acento da tela cresce.
        #expect(
            open.pixels(matching: Theme.tinta.accent, tolerance: 0.03)
                > closed.pixels(matching: Theme.tinta.accent, tolerance: 0.03) + 200,
            "a pastilha ✦ IA não acendeu"
        )
        // E nada mais: nem a calha entre as colunas, nem a lista, nem o corpo.
        #expect(
            open.pixelsDiffering(from: closed, inColumns: 0..<1_440, rows: 300..<820) == 0,
            "a IA do leitor voltou a cobrir as colunas do shell"
        )
    }

    @Test("rodapé usa o ambiente inteiro e ícone do leitor mantém o email")
    func globalAndEmailContextsStaySeparated() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let assistant = RecordingIntegrationAssistant()
        let screen = InboxScreen(store: store, textAssistant: assistant)
        let request = AssistantRequest(
            context: .init(subject: "Ensaio"),
            question: "O que importa?",
            conversation: [.init(speaker: .user, text: "O que importa?")]
        )

        let workspaceConversation = screen.makeConversation(for: .workspace)
        workspaceConversation.ask(request.question)
        await workspaceConversation.waitForIdle()
        guard case let .workspace(workspace) = try #require(await assistant.lastContext()) else {
            Issue.record("O botão global não entregou contexto do ambiente")
            return
        }
        #expect(workspace.emailCount == store.messages.count)
        #expect(workspace.agenda.count == store.agenda.count)
        #expect(workspace.accounts.count == store.accounts.count)

        let selectedID = try #require(store.selectedMessageID)
        let emailConversation = screen.makeConversation(for: .email(selectedID))
        emailConversation.ask(request.question)
        await emailConversation.waitForIdle()
        let emailContext = try #require(await assistant.lastContext())
        switch emailContext {
        case .email, .conversation:
            break
        case .workspace:
            Issue.record("O ícone do leitor perdeu o contexto do email")
        }
    }

    @Test("pergunta no email usa o HTML hidratado, não o snippet da lista")
    func emailQuestionUsesHydratedHTML() async throws {
        let html = "<p>Hi Marcos,</p><p>1. What is/was your role with IGEL OS?</p>"
        let message = Message(
            id: "m1",
            accountID: "conta-a",
            from: Contact(name: "Jayden", address: "jayden@x.com"),
            receivedAt: Date(timeIntervalSince1970: 1_800_000_000),
            subject: "Paid Consultation",
            snippet: "Hi Marcos, I'm reaching out",
            body: [],
            tags: [],
            bucket: .today,
            isRead: false,
            summary: nil,
            detectedEvent: nil
        )
        let fonte = InMemoryMailSource(
            accounts: [Account(
                id: "conta-a", address: "eu@x.com", displayName: "Eu",
                provider: .imap, host: "x", tintLightHex: "#3F6AA1", tintDarkHex: "#8CBAF7"
            )],
            messages: [message],
            agenda: []
        )
        let store = MailStore(
            source: fonte,
            bodyPort: ImmediateAssistantBodyPort(
                body: FetchedBody(
                    paragraphs: ["Hi Marcos, I'm reaching out to gauge your interest."],
                    html: html
                )
            )
        )
        await store.load()
        store.select(message: "m1")
        let assistant = RecordingIntegrationAssistant()
        let screen = InboxScreen(store: store, textAssistant: assistant)
        let request = AssistantRequest(
            context: .init(subject: "Paid Consultation"),
            question: "Traduz e me resume",
            conversation: []
        )

        let conversation = screen.makeConversation(for: .email("m1"))
        conversation.ask(request.question)
        await conversation.waitForIdle()

        #expect(store.messages.first?.body.isEmpty == true)
        guard case let .email(context) = try #require(await assistant.lastContext()) else {
            Issue.record("A pergunta não entregou o email hidratado")
            return
        }
        #expect(context.html == html)
        #expect(context.body.contains("Hi Marcos"))
    }
}

private struct ImmediateAssistantBodyPort: BodyFetching {
    let body: FetchedBody
    func fetchBody(accountID: String, messageID: String) async throws -> FetchedBody { body }
}

private actor ReaderReplyRecorder {
    private var count = 0

    func generate() -> String {
        count += 1
        return "Resposta para revisão."
    }

    func total() -> Int { count }
}

private struct MarkerMailSource: MailSource {
    let account: Account
    let message: Message
    let folders: [MailFolder]

    func accounts() async throws -> [Account] { [account] }
    func messages() async throws -> [Message] { [message] }
    func agenda() async throws -> [AgendaItem] { [] }
    func pendingItems() async throws -> [PendingItem] { [] }
    func folders() async throws -> [MailFolder] { folders }
}

private struct IntegrationAssistant: TextAssisting {
    let modelVersion = "integration"
    func availability() async -> AppleIntelligenceAvailability { .available }
    func answer(
        question: String,
        in conversation: AssistantConversationSnapshot
    ) async throws -> String { "Resposta local" }
    func transform(
        _ text: String,
        using action: WritingAction,
        context: AssistantMailContext?
    ) async throws -> String { "Texto local" }
}

private actor RecordingIntegrationAssistant: TextAssisting {
    nonisolated let modelVersion = "recording-integration"
    private var contexts: [AssistantMailContext] = []

    func availability() async -> AppleIntelligenceAvailability { .available }
    func answer(
        question: String,
        in conversation: AssistantConversationSnapshot
    ) async throws -> String {
        contexts.append(conversation.mailContext)
        return "Resposta local"
    }
    func transform(
        _ text: String,
        using action: WritingAction,
        context: AssistantMailContext?
    ) async throws -> String { "Texto local" }

    func lastContext() -> AssistantMailContext? { contexts.last }
}
