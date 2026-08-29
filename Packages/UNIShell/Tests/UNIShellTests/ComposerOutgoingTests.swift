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
