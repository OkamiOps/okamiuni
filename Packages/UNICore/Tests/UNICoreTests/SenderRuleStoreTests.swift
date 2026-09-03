import Foundation
import Testing

@testable import UNICore

/// A porta de regras em memória, com o mesmo contrato da de disco — a de
/// verdade tem os testes dela em `UNISync`.
final class RegrasEmMemoria: SenderRuling, @unchecked Sendable {
    private let trava = NSLock()
    private var guardadas: [String: SenderRule] = [:]
    private(set) var escritas = 0

    init(_ iniciais: [SenderRule] = []) {
        for regra in iniciais { guardadas[regra.normalizedAddress] = regra }
    }

    func learnSender(_ address: String, neverPriority: Bool, at date: Date) throws {
        trava.lock(); defer { trava.unlock() }
        let chave = SenderRule.normalize(address)
        if neverPriority {
            guardadas[chave] = SenderRule(address: chave, neverPriority: true, createdAt: date)
        } else {
            guardadas[chave] = nil
        }
        escritas += 1
    }

    func senderRules() throws -> [SenderRule] {
        trava.lock(); defer { trava.unlock() }
        return guardadas.values.sorted { $0.address < $1.address }
    }
}

@Suite("A regra do remetente, no store")
@MainActor
struct SenderRuleStoreTests {

    @Test("aprender grava, e a checagem casa mesmo com a caixa trocada")
    func learnWrites() {
        let porta = RegrasEmMemoria()
        let store = MailStore(source: InMemoryMailSource.fixtures, senderRulePort: porta)

        #expect(!store.silencesSender("news@zoho.com"))
        store.learnSender(address: "  News@Zoho.com ", neverPriority: true)
        #expect(store.silencesSender("news@zoho.com"))
        #expect(store.senderRules.map(\.address) == ["news@zoho.com"])
        #expect(porta.escritas == 1)
    }

    @Test("neverPriority: false desfaz — no disco e na tela")
    func revokeUndoes() {
        let porta = RegrasEmMemoria()
        let store = MailStore(source: InMemoryMailSource.fixtures, senderRulePort: porta)
        store.learnSender(address: "news@zoho.com", neverPriority: true)
        store.learnSender(address: "News@Zoho.com", neverPriority: false)

        #expect(!store.silencesSender("news@zoho.com"))
        #expect(store.senderRules.isEmpty)
        #expect((try? porta.senderRules())?.isEmpty == true)
    }

    @Test("a regra sobrevive a uma segunda abertura")
    func rulesSurviveRestart() {
        let porta = RegrasEmMemoria()
        let primeiro = MailStore(source: InMemoryMailSource.fixtures, senderRulePort: porta)
        primeiro.learnSender(address: "news@zoho.com", neverPriority: true)

        let segundo = MailStore(source: InMemoryMailSource.fixtures, senderRulePort: porta)
        #expect(segundo.silencesSender("NEWS@zoho.com"))
    }

    @Test("sem porta, aprender não finge que aprendeu")
    func withoutPortNothingIsLearned() {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        store.learnSender(address: "news@zoho.com", neverPriority: true)
        #expect(store.senderRules.isEmpty)
        #expect(!store.silencesSender("news@zoho.com"))
    }

    @Test("endereço vazio não vira regra")
    func emptyAddressIsIgnored() {
        let porta = RegrasEmMemoria()
        let store = MailStore(source: InMemoryMailSource.fixtures, senderRulePort: porta)
        store.learnSender(address: "   ", neverPriority: true)
        #expect(store.senderRules.isEmpty)
        #expect(porta.escritas == 0)
    }

    @Test("o comando existe, carrega os dois lados e tem desfazer")
    func commandCarriesBothSides() {
        let liga = ContextCommand.learnSender(address: "news@zoho.com", neverPriority: true)
        let desliga = ContextCommand.learnSender(address: "news@zoho.com", neverPriority: false)
        #expect(liga != desliga)
        #expect(liga.undo == desliga)
        #expect(desliga.undo == liga)
    }
}
