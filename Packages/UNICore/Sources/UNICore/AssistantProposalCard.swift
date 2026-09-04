import Foundation

/// Um cartão de ação da gaveta (`design/09-assistente-gaveta.dc.html`): o
/// texto, o verbo do botão primário e o que **um clique** aplica.
///
/// ## Por que isto é um valor, e não um `switch` dentro da `View`
///
/// Duas perguntas moram aqui, e as duas são decisão de produto, não de
/// desenho: **que cartão para qual proposta** (o verbo, o secundário) e
/// **quais ações uma proposta gera** (os efeitos). Escritas dentro de uma
/// `View`, elas não teriam teste — e a segunda é a que decide o que sai pela
/// fila transacional do app.
///
/// ## A regra que não muda
///
/// **Nada aqui executa.** Um `AssistantProposalCard` é texto tipado até
/// alguém clicar, e o que o clique aplica é `Effect` — um `ContextCommand` da
/// mesma fila da Caixa, ou uma das duas escritas de agenda que não têm
/// comando próprio. Não existe efeito de envio: `AssistantAction` não sabe
/// nomear "enviar" (ver a allowlist de `AssistantAction.allKinds`), e por
/// isso nenhuma tradução consegue produzir um.
public struct AssistantProposalCard: Sendable, Hashable, Identifiable {

    /// O que um clique no verbo aplica.
    ///
    /// Quase tudo é `ContextCommand` — a fila transacional com desfazer que a
    /// Caixa, o dashboard e os menus já usam. As duas exceções são escritas
    /// de agenda que **nunca** tiveram comando: `MailStore.addToAgenda(_:from:)`
    /// e `addManualAgendaItem(...)`. Inventar dois casos de `ContextCommand`
    /// para elas aqui seria mexer no menu de contexto inteiro para servir a
    /// gaveta.
    public enum Effect: Sendable, Hashable {
        case command(ContextCommand)
        /// Usa o `DetectedEvent` já persistido da mensagem.
        case addToAgenda(messageID: String)
        /// O bloco da coluna do dia, no idioma do `AgendaItem`.
        case reserveBlock(day: Int, startMinute: Int, minutes: Int, title: String)
    }

    public let id: String
    /// O texto do cartão — o que o 09 escreve em `.act .t`, com o começo em
    /// negrito na tela.
    public let text: String
    /// O porquê, quando a proposta traz um. A gaveta o usa como legenda de
    /// acessibilidade; o cartão do mockup não o pinta.
    public let rationale: String
    /// O botão primário: "Arquivar", "Reservar", "Responder"…
    public let verb: String
    /// "Ver" quando a proposta fala de **uma** mensagem, "Ver a lista" quando
    /// fala de várias, `nil` quando não fala de nenhuma (um bloco de agenda
    /// não tem email para mostrar).
    public let secondary: String?
    /// A mensagem que o secundário abre — a primeira que a proposta cita.
    public let secondaryMessageID: String?
    public let effects: [Effect]
    /// O modelo prometeu "Dá para desfazer" na frase dele. A promessa só
    /// volta ao texto desenhado se a leva de fato desfizer — ver
    /// `displayText`.
    public let claimsUndo: Bool

    public init(
        id: String, text: String, rationale: String, verb: String,
        secondary: String?, secondaryMessageID: String?, effects: [Effect],
        claimsUndo: Bool = false
    ) {
        self.claimsUndo = claimsUndo
        self.id = id
        self.text = text
        self.rationale = rationale
        self.verb = verb
        self.secondary = secondary
        self.secondaryMessageID = secondaryMessageID
        self.effects = effects
    }
}

public extension AssistantProposalCard {

    /// A promessa que o 09 escreve no cartão de arquivar. Ela é **do app**:
    /// o modelo pode escrevê-la na frase dele, mas quem decide se ela é
    /// verdade é a leva.
    static var undoPromise: String { L10n.tr("Dá para desfazer.") }

    /// Frases que modelos já emitiram. Isso é reconhecimento de entrada, não
    /// texto de interface: trocar o idioma do app não pode fazer uma promessa
    /// antiga deixar de ser removida da proposta.
    private static let undoClaimPhrases = [
        "Dá para desfazer.",
        "You can undo this.",
        "Du kannst das rückgängig machen.",
        "Vous pouvez annuler cette action.",
    ]

    /// **A leva deste cartão volta atrás?**
    ///
    /// Volta quando tudo o que ela muda é estado de mensagem (caixa, lido,
    /// sinalizado) ou regra de remetente — o que `ContextCommand.restoreBatch`
    /// sabe devolver. Não volta quando ela escreve na agenda: `addToAgenda` e
    /// `reserveBlock` não são comandos, e um "Desfazer" que devolvesse os
    /// emails e deixasse o compromisso de pé seria meio Desfazer.
    ///
    /// Abrir o composer ou revelar a linha não conta para nenhum dos dois
    /// lados: não há o que desfazer numa janela que abriu.
    var isUndoable: Bool {
        var desfazivel = false
        for efeito in effects {
            switch efeito {
            case .addToAgenda, .reserveBlock:
                return false
            case let .command(comando):
                switch comando {
                case .move, .setRead, .setFlagged, .placeMessage, .learnSender:
                    desfazivel = true
                case .reply, .replyAll, .forward, .revealMessage,
                     .openMessageWindow, .copy, .abrirLink:
                    continue
                default:
                    return false
                }
            }
        }
        return desfazivel
    }

    /// O texto que a gaveta desenha: a frase do modelo, com a promessa de
    /// desfazer de volta **só** quando a leva de fato desfaz.
    ///
    /// A promessa sai da frase crua em `cards(for:turnID:)` justamente para
    /// isto: o modelo escreveu "Dá para desfazer" sobre treze arquivamentos
    /// que não produziam recibo nenhum, e a tela repetiu a promessa dele.
    var displayText: String {
        guard isUndoable, claimsUndo else { return text }
        return text.isEmpty ? Self.undoPromise : "\(text) \(Self.undoPromise)"
    }

    /// A frase do modelo sem a promessa de desfazer, e se ela estava lá.
    static func stripUndoPromise(_ title: String) -> (text: String, claimed: Bool) {
        let limpo = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let promise = undoClaimPhrases.first(where: limpo.hasSuffix) else {
            return (limpo, false)
        }
        let sem = String(limpo.dropLast(promise.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (sem, true)
    }

    /// O verbo do botão primário, pela **primeira** ação da proposta.
    ///
    /// A primeira, e não a mais forte: uma proposta é uma leva ordenada — o
    /// "Arquivar e aprender" do 08 é `.archive` seguido de `.learnSender`, e é
    /// o arquivar que a pessoa está mandando fazer. O resto vai junto porque
    /// a proposta disse que vai.
    ///
    /// **`.reply` diz "Responder", e não "Enviar".** O mockup 09 escreve
    /// "Enviar" nesse cartão, e o desenho é a especificação — mas o mesmo
    /// documento manda o `.reply` abrir o composer com o rascunho **sem
    /// enviar**, e a §4 proíbe a IA de enviar. Um botão "Enviar" que abre uma
    /// janela é um botão que mente; o ruling de 2026-09-03 já decidiu que não
    /// se envia rascunho que a pessoa não viu por inteiro, e na gaveta ela vê
    /// uma frase, não o rascunho. Divergência registrada no relatório.
    static func verb(for action: AssistantAction) -> String {
        switch action {
        case .archive: L10n.tr("Arquivar")
        case .moveToLater: L10n.tr("Depois")
        case .moveToToday: L10n.tr("Trazer para hoje")
        case .markRead: L10n.tr("Marcar como lida")
        case .flag: L10n.tr("Sinalizar")
        case .reply: L10n.tr("Responder")
        case .addToAgenda: L10n.tr("Agendar")
        case .openMessage: L10n.tr("Abrir")
        case .learnSender: L10n.tr("Aprender")
        case .reserveBlock: L10n.tr("Reservar")
        }
    }

    /// A tradução de uma ação para o que o app sabe executar.
    static func effects(of action: AssistantAction) -> [Effect] {
        switch action {
        case let .archive(id):
            [.command(.move(messageID: id, to: .archived))]
        case let .moveToLater(id):
            [.command(.move(messageID: id, to: .later))]
        case let .moveToToday(id):
            [.command(.move(messageID: id, to: .today))]
        case let .markRead(id):
            [.command(.setRead(messageID: id, isRead: true))]
        case let .flag(id):
            [.command(.setFlagged(messageID: id, isFlagged: true))]
        case let .reply(id, _):
            // O rascunho da proposta não viaja no comando: quem semeia o
            // composer é `ComposerSeed`, a partir da mensagem, e um segundo
            // caminho de semeadura faria a resposta da gaveta divergir da do
            // ⌘R no primeiro conserto. Ver a ressalva no relatório.
            [.command(.reply(messageID: id))]
        case let .addToAgenda(id):
            [.addToAgenda(messageID: id)]
        case let .openMessage(id):
            [.command(.revealMessage(messageID: id))]
        case let .learnSender(address):
            [.command(.learnSender(address: address, neverPriority: true))]
        case let .reserveBlock(day, start, minutes, title):
            [.reserveBlock(day: day, startMinute: start, minutes: minutes, title: title)]
        }
    }

    /// Os cartões de um turno. Uma proposta sem ação nenhuma **não vira
    /// cartão**: um botão que não faz nada é pior do que a ausência dele.
    ///
    /// O `turnID` entra no `id` para dois turnos com a mesma proposta não
    /// colidirem na lista do SwiftUI.
    static func cards(
        for proposals: [AssistantProposal], turnID: String
    ) -> [AssistantProposalCard] {
        proposals.enumerated().compactMap { indice, proposta in
            guard let primeira = proposta.actions.first else { return nil }
            let ids = proposta.actions.compactMap(\.messageID)
            let distintos = Set(ids)
            let secundario: String? = distintos.isEmpty
                ? nil
                : (distintos.count > 1 ? L10n.tr("Ver a lista") : L10n.tr("Ver"))
            let frase = stripUndoPromise(proposta.title)
            return AssistantProposalCard(
                id: "\(turnID)#\(indice)",
                text: frase.text,
                rationale: proposta.rationale,
                verb: verb(for: primeira),
                secondary: secundario,
                secondaryMessageID: ids.first,
                effects: proposta.actions.flatMap { effects(of: $0) },
                claimsUndo: frase.claimed
            )
        }
    }
}
