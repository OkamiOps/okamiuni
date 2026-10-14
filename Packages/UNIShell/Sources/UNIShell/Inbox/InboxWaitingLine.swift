import Foundation
import UNICore

/// O que a lista de vidro escreve em acento embaixo de uma linha — e quem vai
/// para a seção "ESPERANDO VOCÊ".
///
/// É tipo puro, sem `View` nenhuma, porque o que a pessoa lê é comportamento:
/// `InboxWaitingLineTests` o afirma sem montar janela.
///
/// **Nenhuma pergunta nova é feita ao modelo.** Tudo sai do que já está
/// guardado: a triagem persistida (`Message.triage`), o prazo que ela cita e o
/// rascunho antecipado que a fila do UNISync escreveu (`ReadyDraft`). O
/// protótipo pede uma frase curta de acento com ✦; esta é a frase.
enum InboxWaitingLine {

    /// A etiqueta que as fixtures do Marco 1 penduram na mensagem que pede
    /// resposta — era ela que a linha desenhava como chip "PRECISA RESPOSTA".
    ///
    /// Existe como saída **de segunda ordem**: numa conta de verdade quem
    /// responde é `Message.triage`, escrito pela análise. Sem triagem
    /// guardada — fixtures, mensagem ainda não analisada — a etiqueta é o
    /// único sinal que a mensagem carrega, e jogá-la fora faria a seção
    /// "Esperando você" nascer sempre vazia nos retratos.
    static let legacyNeedsReplyTag = "Precisa resposta"

    /// Esta mensagem espera a resposta do dono?
    static func waitsForYou(_ message: Message) -> Bool {
        if let triage = message.triage { return triage.needsReply }
        return message.tags.contains { $0.name == legacyNeedsReplyTag }
    }

    /// A frase de acento da linha, ou `nil` quando não há nada honesto a
    /// dizer. Linha sem triagem e sem etiqueta não ganha frase: inventar uma
    /// seria pôr ✦ em cima de um palpite.
    static func phrase(
        for message: Message,
        hasReadyDraft: Bool,
        today: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String? {
        let prazo = message.triage?.deadline?.date
        if waitsForYou(message) {
            let base = prazo.map {
                L10n.tr("Responder até \(deadlineLabel($0, today: today, calendar: calendar, locale: locale))")
            } ?? L10n.tr("Precisa de resposta")
            return hasReadyDraft ? base + L10n.tr(" · resposta pronta") : base
        }
        if let prazo {
            return L10n.tr("Prazo \(deadlineLabel(prazo, today: today, calendar: calendar, locale: locale))")
        }
        return nil
    }

    /// "hoje", "amanhã" ou "qui 27" — o prazo em três caracteres de leitura,
    /// que é o que cabe numa linha de 300pt.
    static func deadlineLabel(
        _ date: Date,
        today: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        if calendar.isDate(date, inSameDayAs: today) { return L10n.tr("hoje") }
        let dias = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: today), to: calendar.startOfDay(for: date)
        ).day ?? 0
        if dias == 1 { return L10n.tr("amanhã") }
        return date.formatted(
            .dateTime.weekday(.abbreviated).day().locale(locale)
        )
    }

    /// A lista partida nas duas seções do protótipo, preservando a ordem que
    /// veio. Devolver duas listas (e não ordenar uma só) é o que mantém a
    /// segunda seção exatamente na ordem de sempre.
    static func split(
        _ conversations: [Conversation]
    ) -> (waiting: [Conversation], rest: [Conversation]) {
        var waiting: [Conversation] = []
        var rest: [Conversation] = []
        for conversa in conversations {
            if waitsForYou(conversa.latest) { waiting.append(conversa) } else { rest.append(conversa) }
        }
        return (waiting, rest)
    }

    static var waitingHeader: String { L10n.tr("ESPERANDO VOCÊ") }
    static var restHeader: String { L10n.tr("MAIS CEDO") }
}
