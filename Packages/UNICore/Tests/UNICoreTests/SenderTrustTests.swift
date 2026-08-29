import Foundation
import Testing
@testable import UNICore

/// Uma porta de confiança em memória, com o mesmo contrato da de disco — o
/// banco tem os testes dele em `UNISync`.
final class ConfiancaEmMemoria: SenderTrusting, @unchecked Sendable {
    private let trava = NSLock()
    private var guardados: Set<String> = []
    /// Quantas vezes o disco foi mesmo chamado: é o que separa "gravou" de
    /// "só mudou na tela".
    private(set) var escritas = 0

    init(_ iniciais: Set<String> = []) { guardados = iniciais }

    func trustSender(_ address: String) throws {
        trava.lock(); defer { trava.unlock() }
        guardados.insert(SenderTrust.normalize(address))
        escritas += 1
    }

    func revokeSenderTrust(_ address: String) throws {
        trava.lock(); defer { trava.unlock() }
        guardados.remove(SenderTrust.normalize(address))
        escritas += 1
    }

    func trustedSenders() throws -> Set<String> {
        trava.lock(); defer { trava.unlock() }
        return guardados
    }
}

@Suite("O remetente de quem as imagens carregam sozinhas")
@MainActor
struct SenderTrustTests {

    @Test("O endereço é normalizado: caixa e espaço não criam um segundo remetente")
    func normalizacao() {
        #expect(SenderTrust.normalize("  NoReply@Calendly.com ") == "noreply@calendly.com")
        #expect(SenderTrust.normalize("noreply@calendly.com") == "noreply@calendly.com")
    }

    @Test("Confiar grava, e a checagem casa mesmo com a caixa trocada")
    func confiarGrava() {
        let porta = ConfiancaEmMemoria()
        let store = MailStore(source: InMemoryMailSource.fixtures, trustPort: porta)

        #expect(!store.trustsSender("noreply@calendly.com"))
        store.trustSender("NoReply@Calendly.com")
        #expect(porta.escritas == 1)
        #expect((try? porta.trustedSenders()) == ["noreply@calendly.com"])
        // A mesma pessoa, escrita de três jeitos.
        #expect(store.trustsSender("noreply@calendly.com"))
        #expect(store.trustsSender("NOREPLY@CALENDLY.COM"))
        #expect(store.trustsSender(" noreply@calendly.com "))
    }

    @Test("A confiança sobrevive a montar o store de novo — é o reinício do app")
    func sobreviveAoReinicio() {
        let porta = ConfiancaEmMemoria()
        let primeiro = MailStore(source: InMemoryMailSource.fixtures, trustPort: porta)
        primeiro.trustSender("noreply@calendly.com")

        let segundo = MailStore(source: InMemoryMailSource.fixtures, trustPort: porta)
        #expect(segundo.trustsSender("noreply@calendly.com"))
    }

    @Test("Revogar revoga — no disco, não só na tela")
    func revogar() {
        let porta = ConfiancaEmMemoria(["noreply@calendly.com"])
        let store = MailStore(source: InMemoryMailSource.fixtures, trustPort: porta)
        #expect(store.trustsSender("noreply@calendly.com"))

        store.revokeSenderTrust("NoReply@Calendly.com")
        #expect(!store.trustsSender("noreply@calendly.com"))
        #expect((try? porta.trustedSenders())?.isEmpty == true)
        // E o reinício não a traz de volta.
        let depois = MailStore(source: InMemoryMailSource.fixtures, trustPort: porta)
        #expect(!depois.trustsSender("noreply@calendly.com"))
    }

    @Test("A confiança é por endereço: outro prefixo do mesmo domínio não herda")
    func naoEhPorDominio() {
        let porta = ConfiancaEmMemoria()
        let store = MailStore(source: InMemoryMailSource.fixtures, trustPort: porta)
        store.trustSender("noreply@calendly.com")
        #expect(!store.trustsSender("notifications@calendly.com"))
        #expect(!store.trustsSender("calendly.com"))
    }

    @Test("Sem porta, ninguém é confiável e nada quebra")
    func semPorta() {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        store.trustSender("noreply@calendly.com")
        #expect(!store.trustsSender("noreply@calendly.com"))
    }

    @Test("Endereço vazio não vira confiança")
    func enderecoVazio() {
        let porta = ConfiancaEmMemoria()
        let store = MailStore(source: InMemoryMailSource.fixtures, trustPort: porta)
        store.trustSender("   ")
        #expect((try? porta.trustedSenders())?.isEmpty == true)
        #expect(!store.trustsSender(""))
    }
}
