import Foundation
import Testing
import UNICore
@testable import UNIShell

/// A faixa das imagens remotas com a segunda ação: "Sempre carregar de
/// <endereço>", e a saída que a desfaz.
///
/// O que a pessoa **lê** é comportamento, e por isso é afirmado aqui sem montar
/// janela nenhuma — as frases e a decisão são estáticas de propósito.
@Suite("A faixa de imagens e a memória de confiança")
@MainActor
struct ReaderTrustBandTests {

    @Test("O botão do sempre mostra o endereço inteiro, não o domínio")
    func rotuloDoSempre() {
        #expect(ReaderHTMLSection.sempreCarregar(de: "noreply@calendly.com")
            == "Sempre carregar de noreply@calendly.com")
        // O que o rótulo promete é o que fica gravado: o endereço.
        #expect(ReaderHTMLSection.sempreCarregar(de: "noreply@calendly.com")?
            .contains("noreply@") == true)
    }

    @Test("Sem endereço não há o que confiar, e o botão não aparece")
    func semEndereco() {
        #expect(ReaderHTMLSection.sempreCarregar(de: "") == nil)
        #expect(ReaderHTMLSection.sempreCarregar(de: "   ") == nil)
    }

    @Test("A linha do remetente confiável diz o que houve e traz a saída")
    func linhaDoConfiavel() {
        #expect(ReaderHTMLSection.imagensCarregadas == "Imagens carregadas · remetente confiável")
        #expect(ReaderHTMLSection.rever == "Rever")
    }

    @Test("O leitor pergunta ao store, e o store lembra entre mensagens")
    func oLeitorConsultaOStore() {
        let porta = ConfiancaEmMemoria()
        let store = MailStore(source: InMemoryMailSource.fixtures, trustPort: porta)
        #expect(!store.trustsSender("noreply@calendly.com"))

        store.trustSender("noreply@calendly.com")
        // A mesma pergunta que `ReaderPane` faz ao desenhar a próxima
        // mensagem: a confiança não mora no `@State` da faixa.
        #expect(store.trustsSender("Noreply@Calendly.com"))
        store.revokeSenderTrust("noreply@calendly.com")
        #expect(!store.trustsSender("noreply@calendly.com"))
    }
}

/// A mesma porta em memória dos testes de `UNICore`, aqui só para a faixa ter
/// contra o que perguntar.
private final class ConfiancaEmMemoria: SenderTrusting, @unchecked Sendable {
    private let trava = NSLock()
    private var guardados: Set<String> = []

    func trustSender(_ address: String) throws {
        trava.lock(); defer { trava.unlock() }
        guardados.insert(SenderTrust.normalize(address))
    }

    func revokeSenderTrust(_ address: String) throws {
        trava.lock(); defer { trava.unlock() }
        guardados.remove(SenderTrust.normalize(address))
    }

    func trustedSenders() throws -> Set<String> {
        trava.lock(); defer { trava.unlock() }
        return guardados
    }
}
