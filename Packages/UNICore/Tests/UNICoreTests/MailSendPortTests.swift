import Foundation
import Testing
@testable import UNICore

/// Uma porta de envio falsa: guarda o que recebeu, ou lança o que o teste
/// mandar lançar.
private final class PortaFalsa: MailSendPort, @unchecked Sendable {
    private let lock = NSLock()
    private var _enviadas: [OutgoingMessage] = []
    private let erro: (any Error)?

    init(erro: (any Error)? = nil) { self.erro = erro }

    var enviadas: [OutgoingMessage] {
        lock.lock()
        defer { lock.unlock() }
        return _enviadas
    }

    func send(_ message: OutgoingMessage) throws {
        if let erro { throw erro }
        lock.lock()
        _enviadas.append(message)
        lock.unlock()
    }
}

private struct ErroDeTeste: Error {}

@Suite("A porta de envio do store")
@MainActor
struct MailSendPortTests {
    private func mensagem() -> OutgoingMessage {
        OutgoingMessage(
            messageID: "id-1@x.com", accountID: "conta-a",
            from: OutgoingAddress(name: "Eu", address: "eu@x.com"),
            to: [OutgoingAddress(name: "Ela", address: "ela@y.com")],
            subject: "Oi", plainText: "corpo"
        )
    }

    @Test("Sem porta, o store diz que não sabe enviar — e não finge que enviou")
    func semPorta() {
        // É o app nas fixtures, e é o Marco 1 intacto. Um `true` aqui faria a
        // janela fechar como se tivesse mandado: o botão mudo na versão mais
        // cara, porque a pessoa acha que a mensagem saiu.
        let store = MailStore(source: InMemoryMailSource.fixtures)
        #expect(!store.canSend)
        #expect(!store.send(mensagem()))
    }

    @Test("Com porta, a mensagem atravessa inteira")
    func comPorta() {
        let porta = PortaFalsa()
        let store = MailStore(source: InMemoryMailSource.fixtures, sendPort: porta)
        #expect(store.canSend)
        #expect(store.send(mensagem()))
        #expect(porta.enviadas.count == 1)
        #expect(porta.enviadas.first?.messageID == "id-1@x.com")
        #expect(porta.enviadas.first?.to.first?.address == "ela@y.com")
    }

    @Test("Porta que falha não engole o erro nem mente que enviou")
    func portaQueFalha() {
        // O `false` é o que faz a janela **ficar aberta** com o rascunho
        // inteiro: fechar aqui perderia o texto da pessoa junto com o erro.
        let store = MailStore(source: InMemoryMailSource.fixtures, sendPort: PortaFalsa(erro: ErroDeTeste()))
        #expect(!store.send(mensagem()))
        #expect(store.loadError != nil)
    }
}
