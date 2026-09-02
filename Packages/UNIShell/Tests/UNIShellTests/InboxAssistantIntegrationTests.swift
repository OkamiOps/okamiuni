import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

@Suite("Assistente integrado ao leitor")
@MainActor
struct InboxAssistantIntegrationTests {
    @Test("o botão contextual do leitor abre a IA e respeita indisponibilidade")
    func readerButtonIsAnAction() {
        var opens = 0
        CliqueDeEnsaio.em(
            ReaderAssistantButton(presentation: .available) { opens += 1 },
            size: CGSize(width: 60, height: 50),
            aY: 13,
            x: 14
        )
        #expect(opens == 1)

        CliqueDeEnsaio.em(
            ReaderAssistantButton(presentation: .modelNotReady) { opens += 1 },
            size: CGSize(width: 60, height: 50),
            aY: 13,
            x: 14
        )
        #expect(opens == 1)
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
            marked.pixelsDiffering(
                from: plain,
                inColumns: 85..<310,
                rows: 18..<80
            ) > 400
        )
    }

    @Test("Gerar resposta do leitor usa o gerador do composer, não a pergunta analítica")
    func readerReplyUsesComposerGenerator() async {
        var generatedReplies = 0
        var analyticalQuestions = 0
        let popover = ReaderIntelligencePopover(
            context: .init(subject: "Website Revamp & SEO", sender: "Max"),
            isAvailable: true,
            onAsk: { _ in
                analyticalQuestions += 1
                return "Análise"
            },
            onGenerateReply: {
                generatedReplies += 1
                return "Hi Max, thank you for the details."
            },
            onUseReply: { _ in },
            onClose: {}
        )
        _ = Render.snapshot(
            popover,
            named: "reader-intelligence-popover",
            size: ReaderIntelligencePopover.defaultSize,
            theme: .tinta
        )

        // Janela offscreen, evento entregue dentro do processo: não toca no
        // mouse, teclado ou foco da sessão do usuário.
        CliqueDeEnsaio.em(
            popover,
            size: ReaderIntelligencePopover.defaultSize,
            aY: 205,
            x: 260
        )
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))

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

    @Test("mini-chat mantém histórico e campo visíveis nos tamanhos mínimo e padrão")
    func readerMiniChatRendersTranscriptAndComposer() throws {
        let answer = """
        ## Situação

        O cliente aprovou a proposta e aguarda a versão final.

        - Confirmar a pauta com Produto
        - Revisar o anexo financeiro
        - Responder até segunda-feira
        """

        for (name, size, theme) in [
            ("minimum", ReaderIntelligencePopover.minimumSize, Theme.tinta),
            ("default-dark", ReaderIntelligencePopover.defaultSize, Theme.noite),
        ] {
            let bitmap = try #require(Render.snapshot(
                ReaderIntelligencePopover(
                    context: .init(subject: "Re: planejamento do lançamento", sender: "Fernanda Lima"),
                    isAvailable: true,
                    initialPhase: .preview(.keyPoints, answer),
                    panelSize: .constant(size),
                    onAsk: { _ in "Resposta de ensaio" },
                    onGenerateReply: { "Resposta para revisão" },
                    onUseReply: { _ in },
                    onClose: {}
                ),
                named: "reader-intelligence-mini-chat-\(name)",
                size: size,
                theme: theme
            ))
            #expect(bitmap.pixelsWide == Int(size.width))
            #expect(bitmap.pixelsHigh == Int(size.height))
        }
    }

    @Test("painel maior redimensiona dentro dos limites e preserva a âncora")
    func readerPanelResizeContract() {
        #expect(ReaderIntelligencePopover.defaultSize == CGSize(width: 520, height: 400))
        #expect(ReaderIntelligencePopover.minimumSize == CGSize(width: 420, height: 300))
        #expect(ReaderIntelligencePopover.maximumSize == CGSize(width: 720, height: 500))

        #expect(
            ReaderIntelligencePopover.resizedSize(
                from: ReaderIntelligencePopover.defaultSize,
                translation: CGSize(width: 100, height: 80)
            ) == CGSize(width: 620, height: 480)
        )
        #expect(
            ReaderIntelligencePopover.resizedSize(
                from: ReaderIntelligencePopover.defaultSize,
                translation: CGSize(width: 1_000, height: 1_000)
            ) == ReaderIntelligencePopover.maximumSize
        )
        #expect(
            ReaderIntelligencePopover.resizedSize(
                from: ReaderIntelligencePopover.defaultSize,
                translation: CGSize(width: -1_000, height: -1_000)
            ) == ReaderIntelligencePopover.minimumSize
        )

        // O painel maior cresce para a direita sem invadir ainda mais a lista
        // de mensagens à esquerda do ponto onde o cartão antigo começava.
        let anchorX: CGFloat = 600
        let oldLeftEdge = anchorX - ReaderIntelligencePopover.anchorWidth
        let newLeftEdge = anchorX
            + ReaderIntelligencePopover.anchorOffset(
                for: ReaderIntelligencePopover.defaultSize.width
            )
            - ReaderIntelligencePopover.defaultSize.width
        #expect(oldLeftEdge == newLeftEdge)
    }

    @Test("controle de expansão aumenta o painel sem automação do desktop")
    func readerPanelExpandControlIsClickable() {
        var size = ReaderIntelligencePopover.defaultSize
        let popover = ReaderIntelligencePopover(
            context: .init(subject: "Quota Increase", sender: "Amazon Web Services"),
            isAvailable: true,
            panelSize: Binding(
                get: { size },
                set: { size = $0 }
            ),
            onAsk: { _ in "" },
            onGenerateReply: { "" },
            onUseReply: { _ in },
            onClose: {}
        )

        CliqueDeEnsaio.em(
            popover,
            size: ReaderIntelligencePopover.defaultSize,
            aY: 27,
            x: 460
        )

        #expect(size == ReaderIntelligencePopover.maximumSize)
    }

    @Test("resposta longa usa a nova área de leitura")
    func longReaderAnswerUsesExpandedViewport() throws {
        let text = """
        A solicitação aumentou o limite de uso excedente para a conta Kiro.

        A Amazon Web Services recusou a primeira tentativa porque os requisitos necessários não estavam completos. O time precisa revisar a configuração, confirmar o responsável e reenviar a solicitação.

        Próximos passos:
        • revisar os requisitos da conta;
        • validar o novo limite com Finanças;
        • reenviar a solicitação até sexta-feira;
        • acompanhar a confirmação da AWS.

        Risco: sem a aprovação, o ambiente pode atingir o teto atual durante a migração.
        """
        let popover = ReaderIntelligencePopover(
            context: .init(subject: "Quota Increase", sender: "Amazon Web Services"),
            isAvailable: true,
            initialPhase: .preview(.keyPoints, text),
            panelSize: .constant(ReaderIntelligencePopover.defaultSize),
            onAsk: { _ in "" },
            onGenerateReply: { "" },
            onUseReply: { _ in },
            onClose: {}
        )

        _ = try #require(Render.snapshot(
            popover,
            named: "reader-intelligence-long-answer",
            size: ReaderIntelligencePopover.defaultSize,
            theme: .tinta
        ))
    }

    @Test("a resposta da IA continua visível quando o painel nasce no botão")
    func readerAnswerDoesNotCollapseInsideButtonOverlay() throws {
        let size = CGSize(width: 620, height: 480)

        func preview(_ text: String, name: String) throws -> NSBitmapImageRep {
            let popover = ReaderIntelligencePopover(
                context: .init(subject: "Migração do workspace", sender: "Paulo Silva"),
                isAvailable: true,
                initialPhase: .preview(.summary, text),
                onAsk: { _ in "" },
                onGenerateReply: { "" },
                onUseReply: { _ in },
                onClose: {}
            )

            // Reproduz a âncora real: o overlay recebe a proposta de tamanho
            // do botão de 32×30 pt. O painel pode transbordar; a área interna
            // da resposta não pode aceitar altura zero por causa disso.
            let anchored = Color.clear
                .frame(width: 32, height: 30)
                .overlay(alignment: .topTrailing) {
                    popover.offset(y: 34)
                }
                .frame(width: size.width, height: size.height, alignment: .topTrailing)

            return try #require(Render.snapshot(
                anchored,
                named: name,
                size: size,
                theme: .tinta
            ))
        }

        let first = try preview(
            "RESPOSTA ALFA: prazo confirmado para sexta-feira.",
            name: "reader-intelligence-answer-alpha"
        )
        let second = try preview(
            "RESPOSTA BRAVO: reunião confirmada para quarta-feira.",
            name: "reader-intelligence-answer-bravo"
        )

        #expect(
            first.pixelsDiffering(from: second) > 150,
            "duas respostas diferentes renderizaram como o mesmo painel vazio"
        )
    }

    @Test("o painel contextual do leitor fica acima do corpo do email")
    func readerPanelLayerRendersOffscreen() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        store.select(bucket: .all)
        store.select(message: "m1")
        let size = CGSize(width: 760, height: 700)
        let generatedReplies = ReaderReplyRecorder()
        let generator: ComposerIntelligenceGenerator = { _ in
            await generatedReplies.generate()
        }

        let closed = try #require(Render.bitmap(
            ReaderPane(
                store: store,
                attachmentSaver: nil,
                intelligence: generator,
                onAskAssistant: { _, _ in "Análise" }
            ),
            size: size,
            theme: .tinta
        ))
        let open = try #require(Render.snapshot(
            ReaderPane(
                store: store,
                debugEmailAssistantOpen: true,
                intelligence: generator,
                onAskAssistant: { _, _ in "Análise" }
            ),
            named: "reader-intelligence-layering",
            size: size,
            theme: .tinta
        ))

        #expect(open.pixelsDiffering(from: closed) > 4_000)
        // O sparkle mora no canto direito; o painel abre para a esquerda,
        // sobre o corpo do email. Se o ScrollView ganhar a camada, aberto e
        // fechado saem idênticos neste retângulo.
        #expect(
            open.pixelsDiffering(
                from: closed,
                inColumns: 280..<500,
                rows: 70..<280
            ) > 1_000
        )

        // O mesmo retângulo precisa ganhar também o hit-test. Este ponto cai
        // no botão "Gerar resposta" do painel e, no código defeituoso, caía
        // no cartão de resumo que estava desenhado por cima.
        CliqueDeEnsaio.em(
            ReaderPane(
                store: store,
                debugEmailAssistantOpen: true,
                intelligence: generator,
                onAskAssistant: { _, _ in "Análise" }
            ),
            size: size,
            aY: 288,
            x: 280
        )
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
        let total = await generatedReplies.total()
        #expect(total == 1)
    }

    /// O painel nasce no botão da IA, **acima** do assunto. Sem `zIndex` na
    /// barra de triagem, o `VStack` do cabeçalho pinta o título por cima — e o
    /// clique cai no assunto, não no "Gerar resposta". É o print do dono.
    @Test("o painel da IA fica acima de um assunto de várias linhas")
    func painelPorCimaDoAssuntoLongo() async throws {
        let account = Account(
            id: "a", address: "conta@dominio.com", displayName: "Conta",
            provider: .imap, host: "host", tintLightHex: "#3E6FA8", tintDarkHex: "#7BA8D9"
        )
        let message = Message(
            id: "m", accountID: "a",
            from: Contact(name: "cursor[bot]", address: "notifications@github.com"),
            receivedAt: Fixtures.today,
            subject: "Re: [aitherion-labs/contion-app] Contion — workflow contábil agêntico (fiscal real, certificado, agentes, WhatsApp) (PR #2)",
            snippet: "pushed", body: ["commit"], tags: [], bucket: .today,
            isRead: true, summary: nil, detectedEvent: nil
        )
        let store = MailStore(
            source: InMemoryMailSource(accounts: [account], messages: [message], agenda: [])
        )
        await store.load()
        store.select(message: "m")
        let size = CGSize(width: 760, height: 700)
        let generator: ComposerIntelligenceGenerator = { _ in "ok" }

        let closed = try #require(Render.bitmap(
            ReaderPane(store: store, intelligence: generator, onAskAssistant: { _, _ in "ok" }),
            size: size, theme: .tinta
        ))
        let open = try #require(Render.bitmap(
            ReaderPane(
                store: store, debugEmailAssistantOpen: true,
                intelligence: generator, onAskAssistant: { _, _ in "ok" }
            ),
            size: size, theme: .tinta
        ))

        // Faixa em que o título de três linhas e o painel se cruzam. Se o
        // assunto ganhar a camada, aberto e fechado saem iguais aqui.
        #expect(
            open.pixelsDiffering(
                from: closed,
                inColumns: 280..<520,
                rows: 100..<170
            ) > 2_000,
            "o assunto está pintando por cima do painel da IA"
        )

        let generatedReplies = ReaderReplyRecorder()
        let clickGenerator: ComposerIntelligenceGenerator = { _ in
            await generatedReplies.generate()
        }
        CliqueDeEnsaio.em(
            ReaderPane(
                store: store, debugEmailAssistantOpen: true,
                intelligence: clickGenerator, onAskAssistant: { _, _ in "ok" }
            ),
            size: size,
            aY: 288,
            x: 280
        )
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(
            await generatedReplies.total() == 1,
            "o clique no painel caiu no assunto em vez do Gerar resposta"
        )
    }

    /// A divisória dados/corpo era overlay do cabeçalho. Overlay pinta **depois**
    /// dos filhos, então a linha cortava o painel da IA ao meio — o print do
    /// dono. O painel agora é overlay da coluna inteira, acima dessa linha.
    @Test("o painel da IA fica acima da divisória do cabeçalho")
    func painelPorCimaDaFaixaDaPilha() async throws {
        let account = Account(
            id: "a", address: "conta@dominio.com", displayName: "Conta",
            provider: .imap, host: "host", tintLightHex: "#3E6FA8", tintDarkHex: "#7BA8D9"
        )
        func msg(_ id: String, at segundos: TimeInterval) -> Message {
            Message(
                id: id, accountID: "a",
                from: Contact(name: "cursor[bot]", address: "notifications@github.com"),
                receivedAt: Date(timeIntervalSince1970: segundos),
                subject: "Re: thread", snippet: "pushed", body: ["commit"],
                tags: [], bucket: .today, isRead: true, summary: nil,
                detectedEvent: nil, threadKey: "t1"
            )
        }
        let store = MailStore(
            source: InMemoryMailSource(
                accounts: [account],
                messages: [msg("c", at: 300), msg("a", at: 100)],
                agenda: []
            )
        )
        await store.load()
        store.select(bucket: .all)
        store.select(message: "c")
        let size = CGSize(width: 760, height: 700)
        let generator: ComposerIntelligenceGenerator = { _ in "ok" }

        let closed = try #require(Render.bitmap(
            ReaderPane(store: store, intelligence: generator, onAskAssistant: { _, _ in "ok" }),
            size: size, theme: .tinta
        ))
        let open = try #require(Render.bitmap(
            ReaderPane(
                store: store, debugEmailAssistantOpen: true,
                intelligence: generator, onAskAssistant: { _, _ in "ok" }
            ),
            size: size, theme: .tinta
        ))

        // Faixa em que a contagem da pilha e o painel se cruzam. Se a hairline
        // da conversa ganhar a camada, aberto e fechado saem iguais aqui.
        #expect(
            open.pixelsDiffering(
                from: closed,
                inColumns: 280..<520,
                rows: 120..<190
            ) > 1_500,
            "a faixa da pilha está pintando por cima do painel da IA"
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

    @Test("popover do leitor fica acima das três colunas e das divisórias")
    func readerPopoverOwnsTheWholeShellLayer() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        store.select(bucket: .all)
        store.select(message: "m1")
        let assistant = IntegrationAssistant()
        let size = CGSize(width: 1_440, height: 858)

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
            named: "reader-intelligence-shell-layering",
            size: size,
            theme: .tinta
        ))

        // O sparkle fica no canto direito do leitor; o painel abre para a
        // esquerda, sobre o corpo. Se o ReaderPane não atravessar o HStack
        // das três colunas, essa faixa continua sendo o email e a diferença
        // despenca.
        #expect(
            open.pixelsDiffering(
                from: closed,
                inColumns: 720..<980,
                rows: 90..<320
            ) > 12_000
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

        _ = try await screen.askAssistant(request, scope: .workspace)
        guard case let .workspace(workspace) = try #require(await assistant.lastContext()) else {
            Issue.record("O botão global não entregou contexto do ambiente")
            return
        }
        #expect(workspace.emailCount == store.messages.count)
        #expect(workspace.agenda.count == store.agenda.count)
        #expect(workspace.accounts.count == store.accounts.count)

        let selectedID = try #require(store.selectedMessageID)
        _ = try await screen.askAssistant(request, scope: .email(selectedID))
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

        _ = try await screen.askAssistant(request, scope: .email("m1"))

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
