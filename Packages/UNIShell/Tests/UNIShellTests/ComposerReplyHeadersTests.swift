import Foundation
import Testing
import UNICore
@testable import UNIShell

private func original(
    _ id: String, rfcMessageID: String? = nil, references: [String] = []
) -> Message {
    Message(
        id: id, accountID: "zoho",
        from: Contact(name: "Marina", address: "marina@x.com"),
        receivedAt: Date(timeIntervalSince1970: 100),
        subject: "Call", snippet: "", body: [], tags: [],
        bucket: .today, isRead: true, summary: nil, detectedEvent: nil,
        rfcMessageID: rfcMessageID, references: references
    )
}

@Suite("A dívida do In-Reply-To, paga")
struct ComposerReplyHeadersTests {

    /// `OutgoingMime.compose` já escrevia os dois cabeçalhos; o que faltava era
    /// alguém preenchê-los, porque a mensagem respondida não guardava o
    /// `Message-ID` dela.
    @Test("A resposta cita a mensagem respondida em In-Reply-To")
    func inReplyTo() {
        let original = original("a", rfcMessageID: "a@x")
        let corrente = ComposerOutgoing.conversa(original)
        #expect(corrente.inReplyTo == "a@x")
        #expect(corrente.references == ["a@x"])
    }

    /// A resposta **acrescenta um elo**, não recomeça a corrente. Sem isso, o
    /// cliente de quem recebe abre uma conversa nova a cada resposta — o mesmo
    /// defeito, do outro lado.
    @Test("References é a corrente da respondida com o Message-ID dela no fim")
    func referencesAcrescenta() {
        let original = original("b", rfcMessageID: "b@x", references: ["a@x"])
        let corrente = ComposerOutgoing.conversa(original)
        #expect(corrente.inReplyTo == "b@x")
        #expect(corrente.references == ["a@x", "b@x"])
    }

    @Test("Sem Message-ID na origem, a mensagem sai como nova — que é a verdade")
    func semOrigem() {
        #expect(ComposerOutgoing.conversa(nil).inReplyTo == nil)
        #expect(ComposerOutgoing.conversa(original("a")).references.isEmpty)
    }

    @Test("A mensagem montada pelo composer carrega os dois campos")
    func mensagemMontada() {
        let original = original("a", rfcMessageID: "a@x", references: ["raiz@x"])
        let saindo = ComposerOutgoing.message(
            accountID: "zoho",
            from: Contact(name: "Eu", address: "eu@meusite.com"),
            to: [Contact(name: "Marina", address: "marina@x.com")],
            cc: [], bcc: [], subject: "Re: Call", plainText: "combinado", html: nil,
            replyingTo: original
        )
        #expect(saindo.inReplyTo == "a@x")
        #expect(saindo.references == ["raiz@x", "a@x"])
    }

    @Test("Mensagem nova não responde a nada")
    func mensagemNova() {
        let saindo = ComposerOutgoing.message(
            accountID: "zoho",
            from: Contact(name: "Eu", address: "eu@meusite.com"),
            to: [Contact(name: "Marina", address: "marina@x.com")],
            cc: [], bcc: [], subject: "Oi", plainText: "oi", html: nil
        )
        #expect(saindo.inReplyTo == nil)
        #expect(saindo.references.isEmpty)
    }
}
