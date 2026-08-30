import Foundation
import Testing
@testable import UNICore

@Suite("Regras de e-mail")
@MainActor
struct EmailRulesTests {
    private func mensagem(
        fromName: String = "Marina Duarte",
        fromAddress: String = "marina@clientepremium.com",
        subject: String = "Reunião de amanhã"
    ) -> Message {
        Message(
            id: "mensagem-1", accountID: "conta-1",
            from: Contact(name: fromName, address: fromAddress),
            receivedAt: Date(timeIntervalSince1970: 1_800_000_000),
            subject: subject, snippet: "Trecho", body: ["Corpo"], tags: [],
            bucket: .today, isRead: false, summary: nil, detectedEvent: nil
        )
    }

    private func defaults() -> (String, UserDefaults) {
        let suite = "okamiuni.test.email-rules.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (suite, defaults)
    }

    @Test("Remetente e assunto casam sem diferenciar caixa ou acento")
    func matcher() {
        let mensagem = mensagem()
        let remetente = EmailRule(
            id: "remetente", name: "Clientes", condition: .senderContains("MARINA"),
            actions: [.markRead]
        )
        let assunto = EmailRule(
            id: "assunto", name: "Reuniões", condition: .subjectContains("REUNIAO"),
            actions: [.archive]
        )
        let desabilitada = EmailRule(
            id: "desabilitada", name: "Nunca", condition: .senderContains("marina"),
            actions: [.flag], enabled: false
        )
        let vazia = EmailRule(
            id: "vazia", name: "Em edição", condition: .subjectContains("   "),
            actions: [.flag]
        )

        #expect(EmailRuleMatcher.matches(remetente, message: mensagem))
        #expect(EmailRuleMatcher.matches(assunto, message: mensagem))
        #expect(!EmailRuleMatcher.matches(desabilitada, message: mensagem))
        #expect(!EmailRuleMatcher.matches(vazia, message: mensagem))
        #expect(EmailRuleMatcher.matchingRules(for: mensagem, in: [desabilitada, assunto, remetente])
            .map(\.id) == ["assunto", "remetente"])
    }

    @Test("As ações locais preservam os demais dados da mensagem")
    func aplicaAcoes() {
        let original = mensagem()
        let resultado = EmailRuleMatcher.apply(
            [.markRead, .archive, .flag], to: original
        )

        #expect(resultado.id == original.id)
        #expect(resultado.subject == original.subject)
        #expect(resultado.isRead)
        #expect(resultado.bucket == .archived)
        #expect(resultado.isFlagged)
        #expect(resultado.body == original.body)
    }

    @Test("Novos campos preservam o envelope v1 e o escopo restringe o matcher")
    func decodificaLegadoEAplicaEscopo() throws {
        let (suite, defaults) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let legacy = EmailRule(
            id: "v1", name: "Legada", condition: .senderContains("marina"),
            actions: [.archive]
        )
        let encoded = try JSONEncoder().encode(legacy)
        var legacyRule = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        // Simula os bytes realmente gravados antes de os campos v2 existirem,
        // em vez de deixar o encoder atual escrever nulos para eles.
        legacyRule.removeValue(forKey: "accountID")
        legacyRule.removeValue(forKey: "forwarding")
        legacyRule.removeValue(forKey: "moveDestination")
        let data = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "rules": [legacyRule],
        ])
        defaults.set(data, forKey: EmailRuleStore.storageKey)

        let reopened = EmailRuleStore(defaults: defaults)
        #expect(reopened.rules == [legacy])

        let scoped = EmailRule(
            name: "Só esta conta", condition: .senderContains("marina"),
            actions: [.flag], accountID: "outra-conta"
        )
        #expect(!EmailRuleMatcher.matches(scoped, message: mensagem()))
    }

    @Test("Encaminhamento aceita só um endereço seguro")
    func validaEnderecoDeEncaminhamento() {
        #expect(EmailRuleForwarding(address: "  arquivo@example.com ")?.address == "arquivo@example.com")
        #expect(EmailRuleForwarding(address: "arquivo@example.com\r\nBcc: alvo@example.com") == nil)
        #expect(EmailRuleForwarding(address: "arquivo@example.com\r\n") == nil)
        #expect(EmailRuleForwarding(address: "arquivo@example.com, outro@example.com") == nil)
        #expect(EmailRuleForwarding(address: "sem-arroba") == nil)
    }

    @Test("O envelope versionado sobrevive a uma nova instância")
    func persisteEReabre() {
        let (suite, defaults) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let regra = EmailRule(
            id: "r1", name: "Boletins", condition: .senderContains("news"),
            actions: [.markRead, .archive]
        )
        let store = EmailRuleStore(defaults: defaults)
        store.upsert(regra)

        #expect(defaults.data(forKey: EmailRuleStore.storageKey) != nil)
        let reopened = EmailRuleStore(defaults: defaults)
        #expect(reopened.rules == [regra])
    }

    @Test("Uma lista sem envelope antigo é lida e sobe de versão na próxima escrita")
    func migraListaLegada() throws {
        let (suite, defaults) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let regra = EmailRule(
            id: "legada", name: "Legada", condition: .subjectContains("fatura"),
            actions: [.flag]
        )
        defaults.set(try JSONEncoder().encode([regra]), forKey: EmailRuleStore.storageKey)

        let store = EmailRuleStore(defaults: defaults)
        #expect(store.rules == [regra])
        store.setEnabled(false, for: regra.id)

        struct Envelope: Decodable {
            let version: Int
            let rules: [EmailRule]
        }
        let data = try #require(defaults.data(forKey: EmailRuleStore.storageKey))
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        #expect(envelope.version == EmailRuleStore.currentVersion)
        #expect(envelope.rules.first?.isEnabled == false)
    }

    @Test("O modo em memória não toca UserDefaults e mantém upsert idempotente")
    func memoria() {
        let regra = EmailRule(
            id: "r1", name: "Primeira", condition: .senderContains("a"), actions: [.flag]
        )
        let store = EmailRuleStore(inMemory: [regra, regra])
        #expect(store.rules.count == 1)

        store.upsert(EmailRule(
            id: regra.id, name: "Atualizada", condition: regra.condition,
            actions: [.markRead]
        ))
        #expect(store.rules.count == 1)
        #expect(store.rule(id: regra.id)?.name == "Atualizada")

        store.remove(id: "ausente")
        store.remove(id: regra.id)
        #expect(store.rules.isEmpty)
    }
}
