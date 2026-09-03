import Foundation

/// O que o assistente pode **propor**. Nada aqui executa: a proposta vira ação
/// depois de um clique, e o clique passa pelo `ContextCommand` de sempre — a
/// mesma fila transacional, o mesmo desfazer.
///
/// **A lista é fechada, e o que ela não tem é a metade importante.** Não existe
/// enviar, apagar, apagar para sempre, esvaziar lixeira, mover para pasta
/// arbitrária nem RSVP. Um modelo que peça qualquer uma dessas coisas não é
/// recusado por política no meio da execução: ele não tem como nomeá-las, e o
/// parser descarta a proposta inteira ao ler um `kind` que não está aqui.
public enum AssistantAction: Sendable, Hashable, Codable {
    case archive(messageID: String)
    case moveToLater(messageID: String)
    case moveToToday(messageID: String)
    case markRead(messageID: String)
    case flag(messageID: String)
    /// Abre o composer com o rascunho. **Não envia** — ver a §4.3.
    case reply(messageID: String, draft: String)
    /// Usa o `DetectedEvent` já persistido da mensagem. Sem evento gravado, a
    /// proposta cai no validador: um compromisso inventado na hora do clique
    /// seria a IA decidindo data por conta própria.
    case addToAgenda(messageID: String)
    case openMessage(messageID: String)
    /// "Arquivar e aprender" do 08, sem o arquivar: a regra por endereço
    /// exato que o `SenderRule` guarda.
    case learnSender(address: String)
    /// O bloco de resposta da coluna do dia. `day` é deslocamento a partir de
    /// hoje, `startMinute` é minuto desde a meia-noite — o idioma do
    /// `AgendaItem`, não uma `Date` que atravessaria fuso.
    case reserveBlock(day: Int, startMinute: Int, minutes: Int, title: String)

    /// O nome que o modelo escreve em `kind`. É o mesmo nome do caso, e é o
    /// vocabulário inteiro que ele tem.
    public var kind: String {
        switch self {
        case .archive: "archive"
        case .moveToLater: "moveToLater"
        case .moveToToday: "moveToToday"
        case .markRead: "markRead"
        case .flag: "flag"
        case .reply: "reply"
        case .addToAgenda: "addToAgenda"
        case .openMessage: "openMessage"
        case .learnSender: "learnSender"
        case .reserveBlock: "reserveBlock"
        }
    }

    /// A allowlist, por extenso. Um teste a trava: acrescentar um caso sem
    /// pensar na §4 é o caminho de "enviar" entrar sem ninguém decidir.
    public static let allKinds: Set<String> = [
        "archive", "moveToLater", "moveToToday", "markRead", "flag",
        "reply", "addToAgenda", "openMessage", "learnSender", "reserveBlock",
    ]

    /// A mensagem a que a ação se refere, quando ela se refere a uma.
    /// `learnSender` e `reserveBlock` não se referem a nenhuma — e é por isso
    /// que isto é opcional em vez de uma `String` vazia mentindo.
    public var messageID: String? {
        switch self {
        case let .archive(id), let .moveToLater(id), let .moveToToday(id),
             let .markRead(id), let .flag(id), let .addToAgenda(id),
             let .openMessage(id):
            return id
        case let .reply(id, _):
            return id
        case .learnSender, .reserveBlock:
            return nil
        }
    }
}

/// Um cartão: um título, o porquê e as ações que um clique aplica de uma vez.
public struct AssistantProposal: Sendable, Hashable {
    public let title: String
    public let actions: [AssistantAction]
    public let rationale: String

    public init(title: String, actions: [AssistantAction], rationale: String) {
        self.title = title
        self.actions = actions
        self.rationale = rationale
    }
}

// MARK: - A forma crua que o modelo escreve

/// Uma ação como o modelo a escreve: um `kind` e os campos que ele conhece.
///
/// Solta de `AssistantAction` de propósito. O `enum` com valores associados é
/// o que o app quer *depois* de conferido; o que chega do modelo é um saco de
/// campos opcionais, e traduzir de um para o outro é justamente onde "kind
/// desconhecido" e "campo faltando" viram descarte em vez de `fatalError`.
public struct AssistantActionOutput: Sendable, Hashable, Codable {
    public let kind: String
    public let messageID: String?
    public let draft: String?
    public let address: String?
    public let day: Int?
    public let startMinute: Int?
    public let minutes: Int?
    public let title: String?

    public init(
        kind: String, messageID: String? = nil, draft: String? = nil,
        address: String? = nil, day: Int? = nil, startMinute: Int? = nil,
        minutes: Int? = nil, title: String? = nil
    ) {
        self.kind = kind
        self.messageID = messageID
        self.draft = draft
        self.address = address
        self.day = day
        self.startMinute = startMinute
        self.minutes = minutes
        self.title = title
    }

    /// A ação de verdade, ou `nil` — e `nil` derruba a proposta inteira.
    public var action: AssistantAction? {
        switch kind {
        case "archive": messageID.map(AssistantAction.archive(messageID:))
        case "moveToLater": messageID.map(AssistantAction.moveToLater(messageID:))
        case "moveToToday": messageID.map(AssistantAction.moveToToday(messageID:))
        case "markRead": messageID.map(AssistantAction.markRead(messageID:))
        case "flag": messageID.map(AssistantAction.flag(messageID:))
        case "addToAgenda": messageID.map(AssistantAction.addToAgenda(messageID:))
        case "openMessage": messageID.map(AssistantAction.openMessage(messageID:))
        case "reply":
            if let messageID, let draft {
                .reply(messageID: messageID, draft: draft)
            } else {
                nil
            }
        case "learnSender": address.map(AssistantAction.learnSender(address:))
        case "reserveBlock":
            if let day, let startMinute, let minutes {
                .reserveBlock(
                    day: day, startMinute: startMinute, minutes: minutes,
                    title: title ?? ""
                )
            } else {
                nil
            }
        default: nil
        }
    }
}

public struct AssistantProposalOutput: Sendable, Hashable, Codable {
    public let title: String
    public let rationale: String?
    public let actions: [AssistantActionOutput]

    public init(title: String, rationale: String? = nil, actions: [AssistantActionOutput]) {
        self.title = title
        self.rationale = rationale
        self.actions = actions
    }

    /// A proposta traduzida, ou `nil` quando **alguma** ação não traduz.
    /// Meia proposta é pior do que nenhuma: o cartão diria "arquivar 5" e o
    /// clique arquivaria 4.
    public var proposal: AssistantProposal? {
        var acoes: [AssistantAction] = []
        acoes.reserveCapacity(actions.count)
        for saida in actions {
            guard let acao = saida.action else { return nil }
            acoes.append(acao)
        }
        return AssistantProposal(
            title: title, actions: acoes, rationale: rationale ?? ""
        )
    }
}

/// O que o modelo devolve quando ele pode propor: a prosa e as propostas.
///
/// `text` é opcional no JSON porque o bloco ```` ```okami-actions ```` do
/// caminho remoto só carrega as propostas — a prosa é o texto em volta dele.
public struct AssistantReply: Sendable, Hashable, Codable {
    public let text: String
    public let proposals: [AssistantProposalOutput]

    public init(text: String = "", proposals: [AssistantProposalOutput]) {
        self.text = text
        self.proposals = proposals
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        proposals = try container.decode([AssistantProposalOutput].self, forKey: .proposals)
    }

    /// As propostas que traduziram. As que citaram um `kind` fora da
    /// allowlist somem aqui, antes de o validador ver o mundo.
    public var assistantProposals: [AssistantProposal] {
        proposals.compactMap(\.proposal)
    }
}

// MARK: - O bloco do caminho remoto

/// O parser do bloco ```` ```okami-actions ````.
///
/// Existe porque provedor remoto e CLI não têm `@Generable`: a única forma
/// estruturada que resta é pedir um bloco no fim da resposta. Três regras, e
/// todas foram escolhidas para o pior caso ser silêncio, nunca erro na cara da
/// pessoa: bloco ausente é resposta normal; bloco quebrado é resposta normal;
/// e **o bloco nunca chega à tela**, nem quando quebrado — ninguém quer ler
/// JSON pela metade no meio de um parágrafo.
public enum AssistantActionsBlock {
    public static let fence = "okami-actions"

    public struct Parsed: Sendable, Hashable {
        public let text: String
        public let proposals: [AssistantProposal]
    }

    /// A instrução que o prompt remoto carrega. Mora aqui, junto do parser,
    /// para o que se pede e o que se lê não divergirem.
    public static let instruction = """
        Se — e somente se — houver ação concreta a propor sobre as mensagens \
        deste contexto, termine a resposta com um único bloco de código aberto \
        por ```\(fence) e fechado por ```, contendo JSON no formato \
        {"proposals":[{"title":"...","rationale":"...","actions":[{"kind":"...", ...}]}]}. \
        Os únicos "kind" existentes são: archive, moveToLater, moveToToday, \
        markRead, flag, reply (com "draft"), addToAgenda, openMessage, \
        learnSender (com "address") e reserveBlock (com "day", "startMinute", \
        "minutes" e "title"). Cada ação sobre mensagem carrega o "messageID" \
        exato do contexto. Não existe enviar, apagar nem responder convite. \
        Sem ação a propor, não escreva bloco nenhum.
        """

    /// A resposta inteira, já separada. Açúcar sobre `parse`, para quem tem
    /// um `AssistantAnswer` para devolver.
    public static func answer(_ raw: String) -> AssistantAnswer {
        let lido = parse(raw)
        return AssistantAnswer(text: lido.text, proposals: lido.proposals)
    }

    /// Separa a prosa das propostas. Nunca lança: a resposta em prosa é o
    /// resultado mínimo aceitável, e ela sempre existe.
    public static func parse(_ raw: String) -> Parsed {
        var texto = raw
        var ultimoJSON: String?
        while let bloco = nextBlock(in: texto) {
            ultimoJSON = bloco.json
            texto.removeSubrange(bloco.range)
        }
        let limpo = texto
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ultimoJSON,
              let dados = ultimoJSON.data(using: .utf8),
              let reply = try? JSONDecoder().decode(AssistantReply.self, from: dados)
        else {
            return Parsed(text: limpo, proposals: [])
        }
        return Parsed(text: limpo, proposals: reply.assistantProposals)
    }

    /// O próximo bloco cercado, com o intervalo que ele ocupa no texto.
    ///
    /// Um bloco **sem** cerca de fechamento conta como bloco até o fim do
    /// texto: uma resposta truncada no meio do JSON é exatamente o caso
    /// "malformado", e deixar a metade na tela é o pior dos dois mundos.
    private static func nextBlock(in text: String) -> (json: String, range: Range<String.Index>)? {
        guard let abertura = text.range(of: "```\(fence)") else { return nil }
        let depois = abertura.upperBound
        if let fechamento = text.range(of: "```", range: depois..<text.endIndex) {
            return (
                String(text[depois..<fechamento.lowerBound]),
                abertura.lowerBound..<fechamento.upperBound
            )
        }
        return (String(text[depois...]), abertura.lowerBound..<text.endIndex)
    }
}

// MARK: - O validador

/// A conferência da §4.1, entre o modelo e o cartão.
///
/// Ela é a razão de o contrato ser tipado: o modelo pode citar um
/// `messageID` que não estava no contexto daquela chamada (alucinado, ou
/// copiado de um turno anterior), e agir sobre ele seria agir sobre uma
/// mensagem que a pessoa não estava olhando.
public enum AssistantProposalValidator {

    /// As propostas que sobrevivem. **Uma ação inválida derruba a proposta
    /// inteira** — o cartão promete um conjunto, e cumprir parte dele é pior
    /// do que não aparecer.
    ///
    /// - Parameters:
    ///   - messageIDs: os ids do `AssistantMailContext` **daquela** chamada.
    ///   - messageIDsWithEvent: quais deles têm `DetectedEvent` persistido.
    ///   - workday: o expediente em que um bloco pode ser reservado.
    public static func validate(
        _ proposals: [AssistantProposal],
        messageIDs: Set<String>,
        messageIDsWithEvent: Set<String>,
        workday: ClosedRange<Int> = FreeSlots.workday
    ) -> [AssistantProposal] {
        proposals.filter { proposta in
            guard !proposta.actions.isEmpty else { return false }
            return proposta.actions.allSatisfy {
                accepts(
                    $0, messageIDs: messageIDs,
                    messageIDsWithEvent: messageIDsWithEvent, workday: workday
                )
            }
        }
    }

    static func accepts(
        _ action: AssistantAction,
        messageIDs: Set<String>,
        messageIDsWithEvent: Set<String>,
        workday: ClosedRange<Int>
    ) -> Bool {
        if let id = action.messageID, !messageIDs.contains(id) { return false }
        switch action {
        case let .addToAgenda(id):
            return messageIDsWithEvent.contains(id)
        case let .reply(_, draft):
            // A mesma regra da resposta sob demanda: texto que só tem espaço
            // em branco não é rascunho, é composer vazio com cara de pronto.
            return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case let .learnSender(address):
            let normalizado = SenderRule.normalize(address)
            return normalizado.contains("@") && !normalizado.hasPrefix("@")
                && !normalizado.hasSuffix("@")
        case let .reserveBlock(day, startMinute, minutes, title):
            guard day >= 0, minutes > 0 else { return false }
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return false
            }
            return workday.contains(startMinute)
                && startMinute + minutes <= workday.upperBound
        case .archive, .moveToLater, .moveToToday, .markRead, .flag, .openMessage:
            return true
        }
    }
}
