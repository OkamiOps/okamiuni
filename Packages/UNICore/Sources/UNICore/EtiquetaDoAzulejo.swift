import Foundation

/// A palavra em versalete que o azulejo do painel 11 escreve: "prazo hoje",
/// "lead novo" ou "esperando".
///
/// **Determinística, e decidida antes de qualquer palpite do modelo.** A tela
/// do dono trazia seis azulejos com "LEAD NOVO" — um "Re:" de uma revista, um
/// pedido de consultoria paga, um boas-vindas de robô e o próprio formulário de
/// teste dele — e uma newsletter marcada "ESPERANDO". Nada disso é lead, e
/// nenhuma delas espera resposta de ninguém. O `intent` do modelo continua
/// entrando na conta, mas só como uma das condições: o que o cabeçalho e o
/// assunto afirmam vence o que o texto sugere, como no ranking.
public enum EtiquetaDoAzulejo: String, Sendable, Hashable, CaseIterable {
    /// O prazo é hoje — é a única etiqueta que acaba.
    case prazoHoje
    /// Alguém que nunca falou com você está pedindo trabalho.
    case leadNovo
    /// Gente esperando a sua resposta.
    case esperando

    /// O que o azulejo escreve.
    public var palavra: String {
        switch self {
        case .prazoHoje: "prazo hoje"
        case .leadNovo: "lead novo"
        case .esperando: "esperando"
        }
    }

    /// Os prefixos que dizem, por escrito, que esta mensagem é a continuação de
    /// uma conversa — e portanto que ela não é um primeiro contato.
    ///
    /// Comparados sem acento e sem caixa, com o dois-pontos: `Resposta` é uma
    /// palavra comum em assunto de email, `Res:` não é.
    static let prefixosDeResposta = ["re:", "res:", "fw:", "fwd:", "enc:", "encaminhada:"]

    /// Este assunto já é resposta ou encaminhamento?
    ///
    /// Aceita o prefixo repetido e numerado que os clientes empilham —
    /// "Re: Re: ", "RE[2]: " — porque é a forma em que ele chega de verdade.
    public static func ehResposta(assunto: String) -> Bool {
        var texto = assunto
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
        var achou = false
        // Em laço: "Re: Fwd: Orçamento" continua sendo resposta.
        podando: while !texto.isEmpty {
            for prefixo in prefixosDeResposta where texto.hasPrefix(prefixo) {
                texto = String(texto.dropFirst(prefixo.count))
                    .trimmingCharacters(in: .whitespaces)
                achou = true
                continue podando
            }
            // "RE[2]:" e "Re(3):" — o mesmo prefixo com a contagem do cliente.
            if let dois = texto.firstIndex(of: ":"),
               let raiz = ["re", "res", "fw", "fwd", "enc"].first(where: {
                   texto.hasPrefix($0)
               }),
               texto[texto.index(texto.startIndex, offsetBy: raiz.count)..<dois]
                   .allSatisfy({ "[]()0123456789 ".contains($0) }) {
                texto = String(texto[texto.index(after: dois)...])
                    .trimmingCharacters(in: .whitespaces)
                achou = true
                continue podando
            }
            break
        }
        return achou
    }

    /// A etiqueta desta mensagem.
    ///
    /// A ordem é da prova mais dura para a mais mole:
    ///
    /// 1. **prazo hoje** — uma data é uma data, e ela vence com robô ou sem;
    /// 2. **lead novo** — só quando *todas* as quatro condições valem: a
    ///    intenção é `lead`, o assunto não é resposta nem encaminhamento, a
    ///    conversa não tem mensagem enviada por você, e o remetente não é
    ///    máquina (o que inclui você mesmo: o formulário de teste do site chega
    ///    com o seu endereço no remetente, e ninguém é lead de si próprio);
    /// 3. **esperando** — o resto que pede gente.
    ///
    /// Devolve `nil` para o que **não vira azulejo de "Esperando você"**:
    /// máquina sem prazo, e o que não pede nada de ninguém. A newsletter que
    /// aparecia como "ESPERANDO" cai exatamente aqui, e vai para o excedente.
    public static func decidir(
        message: Message,
        marks: BulkMailMarks,
        triage: MessageTriage?,
        hasSentInThread: Bool,
        myAddresses: Set<String>,
        today: Date,
        calendar: Calendar = .current
    ) -> EtiquetaDoAzulejo? {
        if let prazo = triage?.deadline?.date,
           calendar.isDate(prazo, inSameDayAs: today) {
            return .prazoHoje
        }

        // Máquina não espera resposta, e máquina não é lead. É a mesma barreira
        // do ranking (`DayPlan.classify`), aplicada aqui para o azulejo nunca
        // divergir da lista de onde ele nasce.
        let eu = Set(myAddresses.map { SenderRule.normalize($0) })
        let remetente = SenderRule.normalize(message.from.address)
        let maquina = marks.isBulk || DayPlan.isAutomated(message)
        guard !maquina else { return nil }

        if triage?.intent == .lead,
           !ehResposta(assunto: message.subject),
           !hasSentInThread,
           !eu.contains(remetente) {
            return .leadNovo
        }

        return DayPlan.pedeGente(triage) && triage?.needsReply == true ? .esperando : nil
    }
}

extension Account {
    /// O nome curto da conta, o que o segmento do filtro escreve.
    ///
    /// O painel escrevia `marcos@okamiops.com` num botão de 12pt porque as
    /// contas de verdade nascem com `displayName` igual ao endereço. Quando o
    /// nome escolhido é um endereço, o que sobra de identidade é o domínio: a
    /// primeira etiqueta dele, capitalizada. `contato@vantion.com.br` vira
    /// "Vantion", e não "Vantion.com.br".
    public var shortName: String {
        let nome = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !nome.isEmpty, !nome.contains("@") { return nome }
        return Self.shortName(from: nome.isEmpty ? address : nome)
    }

    /// "marcos@okamiops.com" → "Okamiops".
    static func shortName(from address: String) -> String {
        let limpo = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let dominio = limpo.split(separator: "@").last.map(String.init) ?? limpo
        let etiqueta = dominio.split(separator: ".").first.map(String.init) ?? dominio
        guard let primeira = etiqueta.first else { return limpo }
        return primeira.uppercased() + etiqueta.dropFirst()
    }
}
