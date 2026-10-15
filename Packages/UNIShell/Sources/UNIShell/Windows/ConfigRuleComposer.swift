import Foundation
import UNICore
import UNISync

/// A regra que a frase descreve, montada e ainda não salva.
///
/// É um valor para a página poder desenhar a frase com as partes ajustáveis
/// sem precisar de uma `EmailRule` válida a cada tecla.
struct ConfigRuleDraft: Hashable {
    enum Field: Hashable { case sender, subject }

    var id = UUID().uuidString
    var name = ""
    var enabled = true
    var field: Field = .subject
    var terms: [String] = []
    /// `nil` é "em qualquer conta".
    var accountID: String?
    var actions: Set<EmailRuleAction> = []
    var moveDestination: SwipeMoveDestination?
    var forwardTo: String?

    init() {}

    init(_ rule: EmailRule) {
        id = rule.id
        name = rule.name
        enabled = rule.enabled
        accountID = rule.accountID
        actions = Set(rule.actions)
        moveDestination = rule.moveDestination
        forwardTo = rule.forwarding?.address
        switch rule.condition {
        case .senderContains(let value):
            field = .sender
            terms = ConfigRuleComposer.splitTerms(value)
        case .subjectContains(let value):
            field = .subject
            terms = ConfigRuleComposer.splitTerms(value)
        }
    }

    /// O texto que a condição procura. Uma regra casa por **um** termo, então
    /// vários termos viram várias regras — ver `rules`.
    var isValid: Bool {
        !terms.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.isEmpty
            && (!actions.isEmpty || moveDestination != nil || forwardTo != nil)
            && (moveDestination == nil || moveDestination?.accountID == accountID)
            && (forwardTo == nil || accountID != nil)
    }

    /// As regras a salvar. O domínio casa por um texto só; a frase do desenho
    /// fala de "“nota fiscal”, “NF-e” ou “boleto”", que são três. Em vez de
    /// inventar um `OR` que o executor não entende, a tela salva uma regra por
    /// termo — com o mesmo nome e as mesmas consequências.
    var rules: [EmailRule] {
        let limpos = terms
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return limpos.enumerated().map { index, term in
            EmailRule(
                id: index == 0 ? id : "\(id)-\(index)",
                name: limpos.count == 1 ? displayName : "\(displayName) · \(term)",
                condition: field == .sender ? .senderContains(term) : .subjectContains(term),
                actions: EmailRuleAction.allCases.filter(actions.contains),
                enabled: enabled,
                accountID: accountID,
                forwarding: forwardTo.flatMap(EmailRuleForwarding.init(address:)),
                moveDestination: moveDestination
            )
        }
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        return terms.first.map { String($0.prefix(40)) } ?? L10n.tr("Regra nova")
    }
}

/// Transforma a frase em português numa regra.
///
/// **Quem monta é o assistente de texto que o app já tem** —
/// `TextAssisting.answer(question:in:)`, o mesmo cano da gaveta e do
/// compositor. Ele recebe um pedido fechado e devolve uma linha de JSON.
/// Quando não há assistente conectado, ou quando a resposta não é o JSON
/// pedido, a montagem cai num reconhecedor **local e determinístico** — e a
/// tela diz qual dos dois montou. Nada aqui finge ter IA: sem assistente, a
/// frase ainda funciona para os casos que o reconhecedor entende, e as partes
/// continuam ajustáveis à mão.
enum ConfigRuleComposer {
    enum Source: Sendable, Hashable {
        case assistant
        case local
    }

    struct Result: Sendable, Hashable {
        var draft: ConfigRuleDraft
        var source: Source
    }

    static func splitTerms(_ value: String) -> [String] {
        [value].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// O pedido que vai ao assistente. Fechado de propósito: um formato só,
    /// sem prosa, para a resposta ser verificável.
    static func prompt(for sentence: String, accounts: [String], folders: [String]) -> String {
        """
        Converta a frase abaixo numa regra de e-mail e responda SOMENTE com uma \
        linha de JSON, sem cercas de código e sem explicação.

        Formato: {"campo":"assunto"|"remetente","termos":["..."],"conta":null|"<id>",\
        "acoes":["marcar_lida","arquivar","sinalizar"],"mover":null|"<pasta>",\
        "encaminhar":null|"<email>","nome":"<nome curto>"}

        Contas possíveis (use o id, ou null para todas): \
        \(accounts.isEmpty ? "nenhuma" : accounts.joined(separator: ", "))
        Pastas possíveis para "mover": \
        \(folders.isEmpty ? "nenhuma" : folders.joined(separator: ", "))

        Frase: \(sentence)
        """
    }

    /// Lê a resposta do assistente. Devolve `nil` quando ela não é o JSON
    /// pedido — e aí o reconhecedor local assume, em vez de a tela mostrar
    /// uma regra inventada a partir de prosa.
    static func parseAssistantAnswer(
        _ answer: String,
        accounts: [AccountStatus],
        destinations: [SwipeMoveDestination]
    ) -> ConfigRuleDraft? {
        guard let start = answer.firstIndex(of: "{"),
              let end = answer.lastIndex(of: "}"),
              start < end
        else { return nil }
        let json = String(answer[start...end])
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        var draft = ConfigRuleDraft()
        if let campo = object["campo"] as? String {
            draft.field = campo.lowercased().hasPrefix("remet") ? .sender : .subject
        }
        draft.terms = (object["termos"] as? [Any] ?? [])
            .compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !draft.terms.isEmpty else { return nil }

        if let conta = object["conta"] as? String,
           let match = accounts.first(where: { $0.accountID == conta || $0.address == conta }) {
            draft.accountID = match.accountID
        }
        let acoes = (object["acoes"] as? [Any] ?? []).compactMap { $0 as? String }
        draft.actions = Set(acoes.compactMap(EmailRuleAction.init(rawValue:)))
        if let mover = object["mover"] as? String {
            draft.moveDestination = destinations.first {
                $0.displayName.localizedCaseInsensitiveCompare(mover) == .orderedSame
            }
            if let destination = draft.moveDestination { draft.accountID = destination.accountID }
        }
        if let encaminhar = object["encaminhar"] as? String,
           EmailRuleForwarding(address: encaminhar) != nil {
            draft.forwardTo = encaminhar
        }
        if let nome = object["nome"] as? String, !nome.trimmingCharacters(in: .whitespaces).isEmpty {
            draft.name = nome
        }
        return draft
    }

    /// O reconhecedor local. Determinístico, sem rede, e com o que ele não
    /// entende deixado em branco para a pessoa ajustar na frase.
    static func parseLocally(
        _ sentence: String,
        accounts: [AccountStatus],
        destinations: [SwipeMoveDestination]
    ) -> ConfigRuleDraft {
        let lower = sentence.lowercased()
        var draft = ConfigRuleDraft()

        draft.field = lower.contains("remetente") || lower.contains("quem manda")
            || lower.contains("vier de") || lower.contains("vem de")
            ? .sender
            : .subject

        draft.terms = quotedTerms(in: sentence)
        if draft.terms.isEmpty { draft.terms = termsAfterKeyword(in: sentence) }

        if lower.contains("arquiv") { draft.actions.insert(.archive) }
        if lower.contains("lida") { draft.actions.insert(.markRead) }
        if lower.contains("estrela") || lower.contains("sinaliz") || lower.contains("marca com") {
            draft.actions.insert(.flag)
        }

        if let destination = destinations.first(where: {
            lower.contains($0.displayName.lowercased())
        }) {
            draft.moveDestination = destination
            draft.accountID = destination.accountID
        }

        if let account = accounts.first(where: { lower.contains($0.address.lowercased()) }) {
            // O endereço citado é a conta quando a frase fala de "chega em";
            // caso contrário ele é o remetente procurado.
            if lower.contains("chega em") || lower.contains("na conta") {
                draft.accountID = account.accountID
            } else if draft.terms.isEmpty {
                draft.field = .sender
                draft.terms = [account.address]
            }
        }

        if let forwarded = forwardAddress(in: sentence), draft.accountID != nil {
            draft.forwardTo = forwarded
        }

        return draft
    }

    /// Os termos entre aspas — curvas ou retas. É como a frase do desenho os
    /// escreve: `“nota fiscal”, “NF-e” ou “boleto”`.
    static func quotedTerms(in sentence: String) -> [String] {
        var termos: [String] = []
        var atual = ""
        var dentro = false
        for character in sentence {
            if "“\"'”".contains(character) {
                if dentro {
                    let limpo = atual.trimmingCharacters(in: .whitespaces)
                    if !limpo.isEmpty { termos.append(limpo) }
                    atual = ""
                    dentro = false
                } else {
                    dentro = true
                }
            } else if dentro {
                atual.append(character)
            }
        }
        return termos
    }

    /// Sem aspas, o termo é o que vem depois de "contendo", "contém", "com" ou
    /// "chegar". Pára na primeira conjunção que começa a consequência.
    static func termsAfterKeyword(in sentence: String) -> [String] {
        let gatilhos = ["contendo", "contém", "contem", "com ", "chegar ", "vier ", "for "]
        let lower = sentence.lowercased()
        for gatilho in gatilhos {
            guard let range = lower.range(of: gatilho) else { continue }
            let resto = sentence[range.upperBound...]
            let cortes = [", ", " e ", " então ", ": ", " move", " mover", " arquiv", " marca"]
            var trecho = String(resto)
            for corte in cortes {
                if let fim = trecho.lowercased().range(of: corte) {
                    trecho = String(trecho[..<fim.lowerBound])
                }
            }
            let termos = trecho
                .components(separatedBy: " ou ")
                .flatMap { $0.components(separatedBy: ",") }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.count >= 3 }
            if !termos.isEmpty { return termos }
        }
        return []
    }

    static func forwardAddress(in sentence: String) -> String? {
        for palavra in sentence.components(separatedBy: .whitespacesAndNewlines) {
            let limpa = palavra.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:()“”\"'"))
            if limpa.contains("@"), EmailRuleForwarding(address: limpa) != nil { return limpa }
        }
        return nil
    }

    /// Quantas mensagens a regra pegaria, contadas nas mensagens **reais** que
    /// este Mac já tem, dentro de uma janela de dias. É a mesma função de
    /// casamento que o executor usa, com `enabled` forçado para a regra em
    /// edição poder ser conferida antes de existir.
    static func matches(
        _ draft: ConfigRuleDraft, in messages: [Message], days: Int, now: Date
    ) -> [Message] {
        let limite = now.addingTimeInterval(-Double(days) * 24 * 60 * 60)
        var regras = draft.rules
        for index in regras.indices { regras[index].enabled = true }
        guard !regras.isEmpty else { return [] }
        return messages
            .filter { $0.receivedAt >= limite }
            .filter { message in regras.contains { EmailRuleMatcher.matches($0, message: message) } }
            .sorted { $0.receivedAt > $1.receivedAt }
    }
}
