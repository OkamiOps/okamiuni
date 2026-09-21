import SwiftUI
import Testing
import UNICore
import UNIDesign
import UNISync
@testable import UNIShell

@Suite("O rascunho vira mensagem")
@MainActor
struct ComposerOutgoingTests {
    private var tema: Theme { ThemeStore().theme }

    private func rico(_ texto: String, _ ajusta: (inout AttributedString) -> Void = { _ in }) -> AttributedString {
        var corpo = AttributedString(texto)
        ajusta(&corpo)
        return corpo
    }

    // MARK: Quando há formatação

    @Test("Texto sem formatação nenhuma não vira HTML")
    func semFormatacao() {
        // Mandar HTML em tudo dobraria o tamanho de toda mensagem e enfiaria a
        // folha de estilo do AppKit em cima de duas linhas que ninguém formatou.
        #expect(!ComposerOutgoing.hasFormatting(rico("só texto")))
        #expect(ComposerOutgoing.html(rico("só texto"), theme: tema) == nil)
    }

    @Test("Negrito, cor, alinhamento e link contam como formatação")
    func comFormatacao() {
        var negrito = rico("oi")
        negrito[BodyStyleAttribute.self] = BodyStyle(bold: true)
        #expect(ComposerOutgoing.hasFormatting(negrito))

        var centrado = rico("oi")
        centrado[BodyAlignmentAttribute.self] = .center
        #expect(ComposerOutgoing.hasFormatting(centrado))

        var comLink = rico("oi")
        comLink.link = URL(string: "https://okamiuni.example")
        #expect(ComposerOutgoing.hasFormatting(comLink))

        var emTabela = rico("oi")
        emTabela[BodyTableAttribute.self] = BodyTableCell(table: 1, row: 0, column: 0, rows: 2, columns: 2)
        #expect(ComposerOutgoing.hasFormatting(emTabela))
    }

    @Test("O estilo padrão não conta como formatação")
    func estiloPadrao() {
        // O editor carimba o estilo padrão em todo trecho que a pessoa digita.
        // Contá-lo como formatação faria **toda** mensagem virar multipart.
        var comPadrao = rico("oi")
        comPadrao[BodyStyleAttribute.self] = .default
        #expect(!ComposerOutgoing.hasFormatting(comPadrao))
    }

    @Test("O corpo formatado sai como HTML de verdade, com o texto dentro")
    func html() throws {
        var negrito = rico("contrato")
        negrito[BodyStyleAttribute.self] = BodyStyle(bold: true)
        let saida = try #require(ComposerOutgoing.html(negrito, theme: tema))
        #expect(saida.lowercased().contains("<html"))
        #expect(saida.contains("contrato"))
    }

    @Test("o HTML enviado ignora a escala visual do composer")
    func htmlUsesStandardTypography() throws {
        var negrito = rico("contrato")
        negrito[BodyStyleAttribute.self] = BodyStyle(size: 20, bold: true)

        let standard = try #require(ComposerOutgoing.html(negrito, theme: .tinta))
        let enlarged = try #require(
            ComposerOutgoing.html(
                negrito, theme: Theme.tinta.applyingTypography(.enlarged)
            )
        )
        #expect(enlarged == standard)
    }

    @Test("Assinatura HTML gerenciada atravessa o composer com sua imagem CID")
    func assinaturaRica() throws {
        let imagem = try InlineSignatureResource(
            contentID: "logo@okamiuni.local", mimeType: "image/png",
            data: Data([0x89, 0x50, 0x4E, 0x47])
        )
        let assinatura = try EmailSignature(
            plainText: "Marcos\nOkamiUNI",
            html: "<strong>Marcos</strong><br>OkamiUNI<img src=\"cid:logo@okamiuni.local\">",
            inlineResources: [imagem]
        )
        let conteudo = ComposerOutgoing.content(
            rico("Olá"), theme: tema, signature: assinatura, signatureIsInserted: true
        )

        #expect(conteudo.plainText == "Olá\n\nMarcos\nOkamiUNI")
        #expect(conteudo.html?.contains("<strong>Marcos</strong>") == true)
        #expect(conteudo.html?.contains("cid:logo@okamiuni.local") == true)
        #expect(conteudo.inlineResources == [imagem])
    }

    @Test("Assinatura HTML fica entre o texto antes e depois do cursor")
    func assinaturaRicaNoCursor() throws {
        let imagem = try InlineSignatureResource(
            contentID: "logo@okamiuni.local", mimeType: "image/png",
            data: Data([0x89, 0x50, 0x4E, 0x47])
        )
        let assinatura = try EmailSignature(
            plainText: "Marcos\nOkamiUNI",
            html: "<strong>Marcos</strong><img src=\"cid:logo@okamiuni.local\">",
            inlineResources: [imagem]
        )
        var corpo = rico("AntesDepois")
        corpo[BodyStyleAttribute.self] = BodyStyle(bold: true)

        let conteudo = ComposerOutgoing.content(
            corpo,
            theme: tema,
            signature: assinatura,
            signatureIsInserted: true,
            signatureOffset: 5
        )

        #expect(conteudo.plainText == "Antes\n\nMarcos\nOkamiUNI\n\nDepois")
        let html = try #require(conteudo.html)
        let antes = try #require(html.range(of: "Antes")?.lowerBound)
        let assinaturaHTML = try #require(html.range(of: "cid:logo@okamiuni.local")?.lowerBound)
        let depois = try #require(html.range(of: "Depois")?.lowerBound)
        #expect(antes < assinaturaHTML && assinaturaHTML < depois)
        #expect(!html.contains("okamiuni-signature-anchor-"))
        #expect(conteudo.inlineResources == [imagem])
    }

    @Test("Assinatura gerenciada desligada não entra silenciosamente numa mensagem")
    func assinaturaNaoInserida() throws {
        let assinatura = try EmailSignature(
            plainText: "Marcos", html: "<strong>Marcos</strong>"
        )

        let conteudo = ComposerOutgoing.content(
            rico("Mensagem sem assinatura"), theme: tema, signature: assinatura,
            signatureIsInserted: false
        )

        #expect(conteudo.plainText == "Mensagem sem assinatura")
        #expect(conteudo.html == nil)
        #expect(conteudo.inlineResources.isEmpty)
    }

    @Test("Assinatura só de texto preserva HTML que a pessoa escreveu")
    func assinaturaDeTextoEmCorpoFormatado() {
        let assinatura = EmailSignature(legacyText: "Marcos\nOkamiUNI")
        var corpo = rico("Olá")
        corpo[BodyStyleAttribute.self] = BodyStyle(bold: true)

        let conteudo = ComposerOutgoing.content(
            corpo, theme: tema, signature: assinatura, signatureIsInserted: true
        )

        #expect(conteudo.plainText == "Olá\n\nMarcos\nOkamiUNI")
        #expect(conteudo.html?.contains("Olá") == true)
        #expect(conteudo.html?.contains("Marcos<br>OkamiUNI") == true)
        #expect(conteudo.inlineResources.isEmpty)
    }

    @Test("Assinatura HTML só com imagem continua sendo incluída")
    func assinaturaSomenteImagem() throws {
        let imagem = try InlineSignatureResource(
            contentID: "marca@okamiuni.local", mimeType: "image/png",
            data: Data([0x89, 0x50, 0x4E, 0x47])
        )
        let assinatura = try EmailSignature(
            plainText: "",
            html: "<img src=\"cid:marca@okamiuni.local\" alt=\"\">",
            inlineResources: [imagem]
        )

        let conteudo = ComposerOutgoing.content(
            rico("Olá"), theme: tema, signature: assinatura, signatureIsInserted: true
        )

        #expect(conteudo.plainText == "Olá")
        #expect(conteudo.html?.contains("cid:marca@okamiuni.local") == true)
        #expect(conteudo.inlineResources == [imagem])
    }

    @Test("API legada continua reconhecendo assinatura no fim do editor")
    func assinaturaLegadaContinuaCompativel() throws {
        let assinatura = try EmailSignature(
            plainText: "Marcos", html: "<strong>Marcos</strong>"
        )
        var corpo = rico("Olá")
        Signature.insert(assinatura.plainText, into: &corpo)

        let conteudo = ComposerOutgoing.content(corpo, theme: tema, signature: assinatura)

        #expect(conteudo.plainText == "Olá\n\nMarcos")
        #expect(conteudo.html?.contains("<strong>Marcos</strong>") == true)
    }

    // MARK: A mensagem

    @Test("A mensagem carrega conta, remetente, destinatários e corpo")
    func mensagem() {
        let mensagem = ComposerOutgoing.message(
            accountID: "conta-a",
            from: Contact(name: "Eu", address: "eu@meudominio.com.br"),
            to: [Contact(name: "Marina", address: "marina@clientepremium.com")],
            cc: [Contact(name: "Sócio", address: "socio@meudominio.com.br")],
            bcc: [],
            subject: "Contrato",
            plainText: "Segue.",
            html: nil
        )
        #expect(mensagem.accountID == "conta-a")
        #expect(mensagem.from.address == "eu@meudominio.com.br")
        #expect(mensagem.to.map(\.address) == ["marina@clientepremium.com"])
        #expect(mensagem.cc.map(\.address) == ["socio@meudominio.com.br"])
        #expect(mensagem.plainText == "Segue.")
        // O `Message-ID` nasce aqui, uma vez — é ele que torna o reenvio da
        // fila seguro depois de um tempo esgotado ambíguo.
        #expect(mensagem.messageID.hasSuffix("@meudominio.com.br"))
    }

    @Test("a resposta leva a original citada no corpo")
    func citingAppendsOriginal() {
        let original = Message(
            id: "m1", accountID: "a",
            from: Contact(name: "Marcos", address: "marcos@okamiops.com"),
            receivedAt: Date(),
            subject: "Cancelado: teste okamiUNI",
            snippet: "", body: ["O teste okamiUNI foi cancelado."], tags: [],
            bucket: .today, isRead: true, summary: nil, detectedEvent: nil
        )
        let citado = ComposerOutgoing.citing(
            original, dateLabel: "31 de ago.",
            onto: ComposerOutgoing.Content(plainText: "Testesteste", html: nil, inlineResources: [])
        )
        #expect(citado.plainText.contains("Testesteste"))
        #expect(citado.plainText.contains("marcos@okamiops.com"))
        #expect(citado.plainText.contains("> O teste okamiUNI foi cancelado."))
        #expect(ComposerOutgoing.citation(original, dateLabel: "31 de ago.").contains("escreveu:"))
    }

    @Test("Chip sem endereço não vira destinatário")
    func chipVazio() {
        // Acontece quando a pessoa aperta ⌘⏎ com o campo meio digitado. Um
        // `RCPT TO:<>` é recusado pelo servidor, e o envio inteiro pararia por
        // causa de um destinatário que ninguém quis pôr.
        let mensagem = ComposerOutgoing.message(
            accountID: "conta-a",
            from: Contact(name: "Eu", address: "eu@x.com"),
            to: [Contact(name: "Marina", address: "marina@y.com"), Contact(name: "meio", address: "  ")],
            cc: [], bcc: [],
            subject: "", plainText: "", html: nil
        )
        #expect(mensagem.to.map(\.address) == ["marina@y.com"])
    }

    @Test("HTML literal conserva documento inteiro e materializa data URI só ao enviar")
    func literalHTMLPreservesDocumentAndMaterializesInlineImage() throws {
        let image = Data([0x89, 0x50, 0x4E, 0x47])
        let source = """
        <html><head><style>.quote { color: #123456; }</style></head><body>
        <table role="presentation"><tr><td><img src="data:image/png;base64,\(image.base64EncodedString())"></td><td>Proposta</td></tr></table>
        </body></html>
        """
        let preserved = ComposerOutgoing.PreservedHTML(html: source, plainText: "Proposta")
        let composed = ComposerOutgoing.preserving(
            .init(plainText: "Olá, segue o contexto.", html: nil, inlineResources: []),
            before: preserved
        )
        let saved = try #require(composed.html)
        #expect(saved.contains("Olá, segue o contexto."))
        #expect(saved.contains("<table role=\"presentation\">"))
        #expect(saved.contains("okamiuni-preserved-html:start"))

        let restored = try #require(
            ComposerOutgoing.extractingPreservedHTML(from: saved, plainText: "Proposta")
        )
        #expect(restored.html == source)
        #expect(restored.plainText == "Proposta")

        let prepared = ComposerOutgoing.materializingInlineResources(composed)
        let html = try #require(prepared.content.html)
        let resource = try #require(prepared.content.inlineResources.first)
        #expect(prepared.warnings.isEmpty)
        #expect(!html.contains("data:image"))
        #expect(html.contains(resource.cidURL))
        #expect(resource.data == image)

        let message = ComposerOutgoing.message(
            accountID: "a", from: .init(name: "Marcos", address: "marcos@example.com"),
            to: [.init(name: "Cliente", address: "cliente@example.com")], cc: [], bcc: [],
            subject: "Enc: proposta", plainText: prepared.content.plainText, html: html,
            inlineResources: prepared.content.inlineResources
        )
        let mime = OutgoingMime.compose(
            message, date: Date(timeIntervalSince1970: 1), includeBcc: false, boundary: "literal"
        )
        #expect(mime.contains("Content-ID: <\(resource.contentID)>"))
        #expect(mime.contains(image.base64EncodedString()))
    }

    @Test("HTML simples reabre no editor com peso e cor")
    func simpleHTMLReturnsToNativeEditor() {
        let editable = ComposerOutgoing.editableText(
            from: "<p><strong><span style=\"color:#336699;font-size:20px\">Proposta</span></strong></p>",
            fallback: "Proposta", theme: tema
        )
        let run = editable.runs.first
        #expect(String(editable.characters).contains("Proposta"))
        #expect(run?.attributes[BodyStyleAttribute.self]?.bold == true)
        #expect(run?.attributes[BodyStyleAttribute.self]?.colorHex == "#336699")
    }

    @Test("introdução formatada mantém estilo após salvar e reabrir duas vezes")
    func preservedIntroductionRetainsFormatting() throws {
        var introduction = ComposerOutgoing.editableText(
            from: "<p><strong><span style=\"color:#336699\">Introdução</span></strong></p>",
            fallback: "Introdução", theme: tema
        )
        var literal = ComposerOutgoing.PreservedHTML(
            html: "<html><body><table><tr><td>Original</td></tr></table></body></html>",
            plainText: "Original"
        )
        for _ in 0..<2 {
            let content = ComposerOutgoing.Content(
                plainText: String(introduction.characters),
                html: ComposerOutgoing.html(introduction, theme: tema), inlineResources: []
            )
            let saved = try #require(ComposerOutgoing.preserving(content, before: literal).html)
            introduction = ComposerOutgoing.editableText(
                from: ComposerOutgoing.extractingEditableHTML(from: saved),
                fallback: "Introdução", theme: tema
            )
            literal = try #require(ComposerOutgoing.extractingPreservedHTML(from: saved, plainText: "Original"))
            #expect(introduction.runs.first?.attributes[BodyStyleAttribute.self]?.bold == true)
            #expect(introduction.runs.first?.attributes[BodyStyleAttribute.self]?.colorHex == "#336699")
            #expect(saved.components(separatedBy: "<!--okamiuni-editable-style:start-->").count == 2)
        }
    }
}

/// **O botão "Enviar" envia.** É a queixa que abriu esta tarefa: o composer do
/// Marco 1 era rico e o botão só escrevia no console.
///
/// A prova corre a **ação do botão** dentro da janela de verdade, pela mesma
/// porta de verificação que a assinatura já usa (`debugInsertSignature`) — fora
/// da tela ninguém clica em nada, e evento sintético é proibido neste projeto.
@Suite("O Enviar da janela")
@MainActor
struct ComposerSendWiringTests {
    /// A porta que a janela deve alcançar. Guarda o que recebeu.
    private final class PortaFalsa: MailSendPort, @unchecked Sendable {
        private let lock = NSLock()
        private var _enviadas: [OutgoingMessage] = []
        var enviadas: [OutgoingMessage] {
            lock.lock()
            defer { lock.unlock() }
            return _enviadas
        }
        func send(_ message: OutgoingMessage) throws {
            lock.lock()
            _enviadas.append(message)
            lock.unlock()
        }
    }

    private final class DraftAndSendPort: MailSendPort, MailDraftPort, @unchecked Sendable {
        private let lock = NSLock()
        private var _drafts: [Message] = []
        private var _draftAttachments: [OutgoingAttachment] = []
        private var _enviadas: [OutgoingMessage] = []
        private var _draftWriteCount = 0

        var drafts: [Message] { lock.lock(); defer { lock.unlock() }; return _drafts }
        var draftAttachments: [OutgoingAttachment] { lock.lock(); defer { lock.unlock() }; return _draftAttachments }
        var enviadas: [OutgoingMessage] { lock.lock(); defer { lock.unlock() }; return _enviadas }
        var draftWriteCount: Int { lock.lock(); defer { lock.unlock() }; return _draftWriteCount }

        func send(_ message: OutgoingMessage) throws {
            lock.lock(); defer { lock.unlock() }
            _enviadas.append(message)
        }

        func saveDraft(_ message: Message) throws {
            try saveDraft(message, attachments: [])
        }

        func saveDraft(_ message: Message, attachments: [OutgoingAttachment]) throws {
            lock.lock(); defer { lock.unlock() }
            _draftWriteCount += 1
            _drafts.removeAll { $0.id == message.id }
            _drafts.append(message)
            _draftAttachments = attachments
        }

        func deleteDraft(id: String) throws {
            lock.lock(); defer { lock.unlock() }
            _drafts.removeAll { $0.id == id }
        }
    }

    private final class AttachmentBytes: AttachmentFetching, @unchecked Sendable {
        let data: Data
        private let lock = NSLock()
        private(set) var requests: [(accountID: String, messageID: String, attachmentID: String)] = []

        init(data: Data) {
            self.data = data
        }

        func fetchAttachment(
            accountID: String, messageID: String, attachmentID: String
        ) async throws -> FetchedAttachment {
            lock.withLock {
                requests.append((accountID, messageID, attachmentID))
            }
            return try FetchedAttachment(
                attachment: .init(
                    id: attachmentID, filename: "proposta.pdf",
                    mimeType: "application/pdf", byteCount: data.count
                ), data: data
            )
        }
    }

    private func janela(_ store: MailStore, id: String, enviando: Bool) {
        EditorProbe.withHostedView(
            ComposerWindow(store: store, mode: .reply(messageID: id), debugSend: enviando),
            size: CGSize(width: 820, height: 660), theme: .tinta
        ) { _ in }
    }

    @Test("apertar Enviar entrega a mensagem à porta de envio")
    func enviaDeVerdade() async throws {
        let porta = PortaFalsa()
        let store = MailStore(source: InMemoryMailSource.fixtures, sendPort: porta)
        await store.load()
        let original = try #require(store.messages.first)

        janela(store, id: original.id, enviando: true)

        let enviada = try #require(porta.enviadas.first)
        // Para quem a janela mostrava, pela conta que a janela mostrava.
        #expect(enviada.to.map(\.address) == [original.from.address])
        #expect(enviada.accountID == original.accountID)
        #expect(enviada.from.address == store.account(original.accountID)?.address)
        #expect(enviada.subject == "Re: \(original.subject)")
        // Um `Message-ID` próprio, que é o que a fila usa para não mandar duas
        // vezes depois de um tempo esgotado ambíguo.
        #expect(!enviada.messageID.isEmpty)
    }

    @Test("Enviar inclui o endereço novo ainda digitado no campo")
    func enviaDestinatarioPendente() async throws {
        let porta = PortaFalsa()
        let store = MailStore(source: InMemoryMailSource.fixtures, sendPort: porta)
        await store.load()
        let conta = try #require(store.accounts.first)
        EditorProbe.withHostedView(
            ComposerWindow(
                store: store, mode: .new(accountID: conta.id),
                debugSuggestion: .init(slot: .to, query: "novo@example.com"), debugSend: true
            ),
            size: CGSize(width: 820, height: 620), theme: .tinta
        ) { _ in }
        #expect(porta.enviadas.first?.to.map(\.address) == ["novo@example.com"])
    }

    @Test("Texto inválido pendente impede enviar só aos chips já existentes")
    func invalidoPendenteImpedeEnvioParcial() async throws {
        let porta = PortaFalsa()
        let store = MailStore(source: InMemoryMailSource.fixtures, sendPort: porta)
        await store.load()
        let original = try #require(store.messages.first)
        EditorProbe.withHostedView(
            ComposerWindow(
                store: store, mode: .reply(messageID: original.id),
                debugSuggestion: .init(slot: .cc, query: "email incompleto"), debugSend: true
            ),
            size: CGSize(width: 820, height: 620), theme: .tinta
        ) { _ in }
        #expect(porta.enviadas.isEmpty)
    }

    @Test("Enviar sem destinatário nenhum não manda nada, e a janela fica aberta")
    func semDestinatario() async throws {
        // Acontece o tempo todo: ⌘⏎ com o campo "Para" ainda vazio. Mandar
        // assim faria o servidor recusar o envelope e **parar a fila da conta**
        // por causa de um engano de digitação; fechar a janela perderia o
        // rascunho junto.
        let porta = PortaFalsa()
        let store = MailStore(source: InMemoryMailSource.fixtures, sendPort: porta)
        await store.load()
        let conta = try #require(store.accounts.first)

        EditorProbe.withHostedView(
            ComposerWindow(store: store, mode: .new(accountID: conta.id), debugSend: true),
            size: CGSize(width: 820, height: 620), theme: .tinta
        ) { _ in }

        #expect(porta.enviadas.isEmpty)
    }

    @Test("apertar Salvar rascunho grava na caixa Rascunhos")
    func salvaRascunhoDeVerdade() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let original = try #require(store.messages.first)

        EditorProbe.withHostedView(
            ComposerWindow(
                store: store, mode: .reply(messageID: original.id),
                debugSaveDraft: true
            ),
            size: CGSize(width: 820, height: 660), theme: .tinta
        ) { _ in }

        let rascunhos = store.messages.filter { $0.bucket == .drafts }
        #expect(rascunhos.count == 1)
        #expect(rascunhos.first?.to.map(\.address) == [original.from.address])
        #expect(rascunhos.first?.subject.hasPrefix("Re:") == true)
        #expect(store.count(for: .drafts) == 1)
        #expect(rascunhos.first?.threadKey == original.id)
        let rota = ComposerRoute.editor(for: try #require(rascunhos.first))
        #expect(rota == .draft(messageID: try #require(rascunhos.first?.id)))
    }

    /// **O encaminhar do email, de ponta a ponta.**
    ///
    /// O dono do projeto relatou que encaminhar também não funcionava. A
    /// investigação da M3-15 não achou furo neste caminho — `ComposerRoute`
    /// carrega o prefixo `enc:`, a janela lê o modo, a conta vem da mensagem
    /// encaminhada (`fromAccountID` é nulo no modo `.forward`, e o `account`
    /// cai em `store.account(repliedMessage.accountID)`) e `store.canSend` é
    /// verdadeiro sempre que há banco. Este teste é a prova disso onde ela
    /// pode existir sem clique: do seed até a fila.
    ///
    /// O que faltava de fato era o "Enviar" da **faixa de resposta** e o
    /// "Encaminhar convite" da janela de compromisso — os dois consertados
    /// nesta tarefa.
    @Test("encaminhar um email monta o corpo citado e entra na fila")
    func encaminhaDePontaAPonta() async throws {
        let porta = PortaFalsa()
        let store = MailStore(source: InMemoryMailSource.fixtures, sendPort: porta)
        await store.load()
        let original = try #require(store.messages.first { !$0.body.isEmpty })
        let conta = try #require(store.account(original.accountID))
        // Sem porta a janela cairia no `logSend` e fecharia fingindo sucesso —
        // é o guarda que a queixa do dono acusaria se ele fosse o problema.
        #expect(store.canSend)

        let seed = ComposerSeed.forward(
            of: original, dateLabel: DateLabels.eventDate(original.receivedAt)
        )
        let mensagem = ComposerOutgoing.message(
            accountID: conta.id,
            from: Contact(name: conta.displayName, address: conta.address),
            to: [Contact(name: "Sócio", address: "socio@meusite.com")],
            cc: [], bcc: [],
            subject: seed.subject,
            plainText: seed.body,
            html: nil,
            // Encaminhar não é responder: `In-Reply-To` enfiaria a mensagem
            // dentro da conversa original na caixa de quem recebe.
            replyingTo: nil
        )
        #expect(store.send(mensagem))

        let enviada = try #require(porta.enviadas.first)
        #expect(enviada.subject == "Enc: \(original.subject)")
        #expect(enviada.accountID == original.accountID)
        #expect(enviada.plainText.contains("Mensagem encaminhada"))
        #expect(enviada.plainText.contains(original.from.address))
        let primeiroParagrafo = try #require(original.body.first)
        #expect(enviada.plainText.contains(primeiroParagrafo))
        #expect(enviada.inReplyTo == nil)
        #expect(enviada.references.isEmpty)
    }

    /// A rota que o menu e o atalho usam para abrir a janela de encaminhar —
    /// se ela chegasse como resposta, a janela semearia o seed errado e o
    /// "Encaminhar" mandaria uma resposta ao remetente.
    @Test("a rota de encaminhar chega do outro lado como encaminhar")
    func rotaDeEncaminhar() {
        let valor = ComposerRoute.forward(messageID: "m1").value
        #expect(ComposerRoute.parse(valor) == .forward(messageID: "m1"))
        #expect(ComposerWindow.Mode(ComposerRoute.parse(valor)) == .forward(messageID: "m1"))
    }

    @Test("a mesma janela sem apertar nada não manda mensagem nenhuma")
    func semApertar() async throws {
        let porta = PortaFalsa()
        let store = MailStore(source: InMemoryMailSource.fixtures, sendPort: porta)
        await store.load()
        let original = try #require(store.messages.first)

        janela(store, id: original.id, enviando: false)

        #expect(porta.enviadas.isEmpty)
    }

    @Test("encaminhar rico salva, reabre e envia HTML, CID e bytes reais")
    func richForwardSaveReopenAndSend() async throws {
        let file = Data([0x25, 0x50, 0x44, 0x46])
        let image = Data([0x89, 0x50, 0x4E, 0x47])
        let account = Account(
            id: "a", address: "marcos@example.com", displayName: "Marcos",
            provider: .imap, host: "example.com", tintLightHex: "#111111", tintDarkHex: "#eeeeee"
        )
        let original = Message(
            id: "original", accountID: account.id,
            from: .init(name: "Ana", address: "ana@example.com"),
            receivedAt: Date(timeIntervalSince1970: 1), subject: "Proposta", snippet: "Tabela",
            body: ["Tabela da proposta"], tags: [], bucket: .today, isRead: true,
            summary: nil, detectedEvent: nil,
            bodyHTML: "<html><body><table><tr><td><img src=\"data:image/png;base64,\(image.base64EncodedString())\"></td><td>Proposta</td></tr></table></body></html>",
            attachments: [.init(id: "pdf", filename: "proposta.pdf", mimeType: "application/pdf", byteCount: file.count)]
        )
        let port = DraftAndSendPort()
        let attachmentPort = AttachmentBytes(data: file)
        let store = MailStore(
            source: InMemoryMailSource(accounts: [account], messages: [original], agenda: []),
            attachmentPort: attachmentPort, sendPort: port, draftPort: port
        )
        await store.load()

        await withHostedComposer(
            ComposerWindow(
                store: store, mode: .forward(messageID: original.id),
                debugSaveDraft: true, debugBody: "Olá, encaminho a proposta."
            ), until: { !port.drafts.isEmpty }
        )

        #expect(
            !port.drafts.isEmpty,
            "forward draft was not saved; attachment requests: \(attachmentPort.requests.count); draft writes: \(port.draftWriteCount); store error: \(store.loadError ?? "none")"
        )
        let saved = try #require(port.drafts.first)
        let savedHTML = try #require(saved.bodyHTML)
        #expect(savedHTML.contains("Olá, encaminho a proposta."))
        #expect(savedHTML.contains("<table>"))
        #expect(savedHTML.contains("data:image/png;base64"))
        #expect(port.draftAttachments.first?.data == file)

        await withHostedComposer(
            ComposerWindow(
                store: store, mode: .draft(messageID: saved.id),
                debugSuggestion: .init(slot: .to, query: "cliente@example.com"), debugSend: true
            ), until: { !port.enviadas.isEmpty }
        )

        let sent = try #require(port.enviadas.first)
        let sentHTML = try #require(sent.html)
        let resource = try #require(sent.inlineResources.first)
        #expect(sent.to.map(\.address) == ["cliente@example.com"])
        #expect(sentHTML.contains("Olá, encaminho a proposta."))
        #expect(sentHTML.contains("<table>"))
        #expect(sentHTML.contains(resource.cidURL))
        #expect(!sentHTML.contains("data:image"))
        #expect(sent.attachments.first?.data == file)

        let mime = OutgoingMime.compose(
            sent, date: Date(timeIntervalSince1970: 1), includeBcc: false, boundary: "reopened"
        )
        #expect(mime.contains("Content-ID: <\(resource.contentID)>"))
        #expect(mime.contains(file.base64EncodedString()))
    }

    /// A porta de anexos suspende a tarefa do compositor. Ceder o ator aqui
    /// permite retomar essa tarefa antes de fechar a janela fora da tela.
    private func withHostedComposer<V: View>(
        _ view: V, until finished: @MainActor () -> Bool
    ) async {
        let size = CGSize(width: 820, height: 660)
        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -50_000, y: -50_000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view.theme(.tinta).frame(width: size.width, height: size.height))
        defer { window.close() }
        let deadline = Date().addingTimeInterval(5)
        while !finished(), Date() < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

}
