import Foundation
import Testing
import UNICore
import UNISync
@testable import UNIShell

/// A frase em português virando regra, e a contagem do que ela pegaria.
///
/// A contagem é o ponto: a prévia promete "Pegaria N e-mails" antes de a regra
/// existir, e essa promessa só vale se N sair das mensagens **reais** deste
/// Mac, pela mesma função de casamento que o executor usa. Um número estimado
/// ali seria a versão em dados do botão mudo.
@Suite("A frase que vira regra")
struct ConfigRuleComposerTests {
    private let agora = Date(timeIntervalSince1970: 1_800_000_000)

    private func mensagem(
        id: String, de: String, endereco: String, assunto: String, diasAtras: Double,
        categoria: MailCategory? = nil
    ) -> Message {
        Message(
            id: id,
            accountID: "conta",
            from: Contact(name: de, address: endereco),
            receivedAt: agora.addingTimeInterval(-diasAtras * 24 * 60 * 60),
            subject: assunto,
            snippet: assunto,
            body: [],
            tags: [],
            bucket: .today,
            isRead: false,
            summary: nil,
            detectedEvent: nil,
            category: categoria
        )
    }

    private var caixa: [Message] {
        [
            mensagem(id: "1", de: "Contábil", endereco: "nf@exato.com.br",
                     assunto: "Sua nota fiscal de setembro", diasAtras: 1, categoria: .transactions),
            mensagem(id: "2", de: "Vivo", endereco: "cobranca@vivo.com.br",
                     assunto: "Boleto com vencimento em 20/09", diasAtras: 2, categoria: .transactions),
            mensagem(id: "3", de: "Marina", endereco: "marina@cliente.com",
                     assunto: "Agenda da próxima semana", diasAtras: 3, categoria: .primary),
            // Fora da janela de sete dias: a prévia não pode contá-la.
            mensagem(id: "4", de: "Nuvem Fiscal", endereco: "nfe@nuvem.com.br",
                     assunto: "Emissão de nota fiscal concluída", diasAtras: 20),
        ]
    }

    @Test("a contagem sai das mensagens reais e só da janela de sete dias")
    func contagemMedida() {
        var draft = ConfigRuleDraft()
        draft.field = .subject
        draft.terms = ["nota fiscal", "boleto"]
        draft.actions = [.markRead]

        let pegos = ConfigRuleComposer.matches(draft, in: caixa, days: 7, now: agora)
        #expect(pegos.map(\.id) == ["1", "2"], "contou \(pegos.map(\.id))")

        // A mesma regra numa janela maior alcança a de vinte dias atrás.
        let trintaDias = ConfigRuleComposer.matches(draft, in: caixa, days: 30, now: agora)
        #expect(trintaDias.count == 3)
    }

    /// A regra em edição nasce desligada enquanto não é salva, e uma regra
    /// desligada nunca casa — `EmailRuleMatcher` é explícito nisso. Sem forçar
    /// `enabled` na conferência, a prévia diria sempre "Pegaria 0 e-mails".
    @Test("a prévia conta mesmo com a regra ainda não salva")
    func previaIgnoraOInterruptor() {
        var draft = ConfigRuleDraft()
        draft.enabled = false
        draft.field = .subject
        draft.terms = ["boleto"]
        draft.actions = [.archive]
        #expect(ConfigRuleComposer.matches(draft, in: caixa, days: 7, now: agora).count == 1)
    }

    @Test("vários termos viram várias regras, com a mesma consequência")
    func umaRegraPorTermo() {
        var draft = ConfigRuleDraft()
        draft.name = "Notas fiscais"
        draft.field = .subject
        draft.terms = ["nota fiscal", "NF-e", "boleto"]
        draft.actions = [.markRead]

        let regras = draft.rules
        #expect(regras.count == 3)
        #expect(regras.allSatisfy { $0.actions == [.markRead] })
        #expect(Set(regras.map(\.id)).count == 3, "duas regras com o mesmo id se sobrescreveriam")
        #expect(regras[0].condition == .subjectContains("nota fiscal"))
    }

    @Test("o reconhecedor local entende a frase do desenho")
    func reconhecedorLocal() {
        let draft = ConfigRuleComposer.parseLocally(
            "quando chegar nota fiscal ou boleto, move para Financeiro e marca como lida",
            accounts: [],
            destinations: []
        )
        #expect(draft.field == .subject)
        #expect(draft.terms.contains("nota fiscal"))
        #expect(draft.terms.contains("boleto"))
        #expect(draft.actions.contains(.markRead))
    }

    @Test("as aspas do desenho delimitam os termos")
    func termosEntreAspas() {
        let termos = ConfigRuleComposer.quotedTerms(
            in: "com assunto contendo “nota fiscal”, “NF-e” ou “boleto”"
        )
        #expect(termos == ["nota fiscal", "NF-e", "boleto"])
    }

    /// A montagem pela IA só vale se a resposta for o JSON pedido. Prosa não
    /// vira regra: cai no reconhecedor local, e a tela diz qual dos dois montou.
    @Test("uma resposta que não é o JSON pedido não vira regra")
    func respostaForaDoFormato() {
        #expect(ConfigRuleComposer.parseAssistantAnswer(
            "Claro! Posso montar essa regra para você.",
            accounts: [], destinations: []
        ) == nil)

        let boa = ConfigRuleComposer.parseAssistantAnswer(
            #"{"campo":"remetente","termos":["contabil@exato.com.br"],"conta":null,"acoes":["arquivar"],"mover":null,"encaminhar":null,"nome":"Contador"}"#,
            accounts: [], destinations: []
        )
        #expect(boa?.field == .sender)
        #expect(boa?.terms == ["contabil@exato.com.br"])
        #expect(boa?.actions == [.archive])
        #expect(boa?.name == "Contador")
    }

    @Test("sem termo nenhum a regra não é salvável")
    func regraVaziaNaoSalva() {
        var draft = ConfigRuleDraft()
        draft.actions = [.archive]
        #expect(!draft.isValid)
        draft.terms = ["  "]
        #expect(!draft.isValid, "espaço em branco não é um termo")
        draft.terms = ["boleto"]
        #expect(draft.isValid)
    }
}
