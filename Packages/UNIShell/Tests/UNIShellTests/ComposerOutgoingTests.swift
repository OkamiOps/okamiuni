import SwiftUI
import Testing
import UNICore
import UNIDesign
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
}
