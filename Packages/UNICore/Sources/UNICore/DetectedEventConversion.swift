import Foundation

/// Converte um `DetectedEvent` — um instante absoluto que uma mensagem carrega
/// — no `AgendaItem` que a trilha lateral do email, o Dia, a Semana e o Mês
/// sabem desenhar.
///
/// Mora em `UNICore`, fora de qualquer `View`, pela mesma razão de
/// `AgendaSummary`, `PaneLayout`, `RichBody` e `SwipeActions`: `View` é
/// `@MainActor` implícito no Swift 6, e um `static` lá dentro trapa quando um
/// teste nonisolated o chama.
///
/// ## A fronteira de fuso
///
/// `AgendaItem` modela horário como minutos desde a meia-noite e dia como um
/// deslocamento inteiro **de propósito** — ver o comentário de
/// `AgendaItem.dayOffset`. Esta é a única ponte entre aquele mundo e o
/// `Date`/`TimeInterval` de `DetectedEvent`, e ela cruza para o outro lado
/// **uma vez só**, aqui: lê a hora e o minuto de parede pelo calendário
/// (`calendar.component(.hour/.minute, from:)`), a mesma técnica que
/// `FixtureTimeZoneTests.derivedMinuteMatchesConstant` trava contra
/// `Fixtures.nowMinute`. Não subtrai `Date` de `Date` em segundos e divide por
/// 60 — essa conta atravessa qualquer troca de horário de verão no meio do
/// intervalo e dá um minuto errado sem que o fuso da máquina tenha culpa
/// nenhuma.
public enum DetectedEventConversion {

    /// O `id` estável de um compromisso criado a partir do email `messageID`.
    ///
    /// Determinístico, não `UUID()`: clicar duas vezes em "Colocar na agenda"
    /// na mesma mensagem recalcula o **mesmo** `id`, e é isso que deixa
    /// `MailStore.addToAgenda` reconhecer o segundo clique como repetição —
    /// em vez de duplicar o compromisso na trilha, no Dia, na Semana e no Mês.
    public static func agendaID(forMessageID messageID: String) -> String {
        prefix + messageID
    }

    /// O prefixo que marca um compromisso **nascido de um email**.
    ///
    /// Ele não é decoração do `id`: é a única coisa que distingue o que o app
    /// criou do que veio da agenda. E é essa distinção que decide se "Tirar da
    /// agenda" pode existir — tirar um compromisso de fixture não teria efeito
    /// nenhum além da sessão, porque no Marco 1 não há escrita na agenda de
    /// verdade.
    public static let prefix = "email-"

    /// Este compromisso foi criado a partir de um email?
    public static func isFromEmail(_ itemID: String) -> Bool {
        itemID.hasPrefix(prefix) && itemID.count > prefix.count
    }

    /// De qual mensagem ele veio, se veio de alguma.
    public static func messageID(forAgendaID itemID: String) -> String? {
        guard isFromEmail(itemID) else { return nil }
        return String(itemID.dropFirst(prefix.count))
    }

    /// O `AgendaItem` que este `DetectedEvent` vira, contado contra
    /// `referenceDay` (`Fixtures.today` no app inteiro).
    ///
    /// **Decisão: um evento que atravessa a meia-noite fica no dia em que
    /// começa, e termina às 23:59 desse dia (minuto 1439).**
    ///
    /// `AgendaItem` não tem como representar um compromisso espalhado por
    /// dois `dayOffset` — é um inteiro só, não uma faixa de dias. As
    /// alternativas eram descartar o compromisso (o botão "Colocar na
    /// agenda" voltaria a ser mudo para qualquer email cujo detalhe cruze a
    /// meia-noite) ou desenhar dois `AgendaItem` (duas entradas para uma
    /// "coisa" só, que reaparecem em dobro em menu, busca e no "próximo
    /// compromisso" da trilha). Recortar no fim do dia em que ele começa é o
    /// que sobra sem inventar um segundo item: o compromisso continua visível
    /// na hora certa, no dia em que a mensagem disse que ele começa.
    public static func agendaItem(
        from event: DetectedEvent,
        id: String,
        accountID: String,
        referenceDay: Date,
        calendar: Calendar = .current
    ) -> AgendaItem {
        let referenceDayStart = calendar.startOfDay(for: referenceDay)
        let eventDayStart = calendar.startOfDay(for: event.start)
        let dayOffset = calendar.dateComponents(
            [.day], from: referenceDayStart, to: eventDayStart
        ).day ?? 0

        let startMinute = minuteOfDay(event.start, calendar: calendar)
        // Só conta como "atravessou a meia-noite" quando o FIM cai num dia de
        // calendário diferente do início — não quando o minuto do fim é
        // menor por acaso de outra conta. `duration` de `DetectedEvent` nunca
        // é negativa, então a única forma de o fim cair num dia diferente é
        // ter passado da meia-noite.
        let crossesMidnight = calendar.startOfDay(for: event.end) != eventDayStart
        let endMinute = crossesMidnight ? 1439 : minuteOfDay(event.end, calendar: calendar)

        return AgendaItem(
            id: id,
            title: event.label,
            startMinute: startMinute,
            // `max` é a mesma trava de sempre: nunca terminar antes de começar,
            // mesmo que uma composição futura de `calendar` faça o recorte
            // acima devolver um minuto menor que o de início.
            endMinute: max(startMinute, endMinute),
            accountID: accountID,
            dayOffset: dayOffset
        )
    }

    /// Hora e minuto de parede, lidos do calendário — nunca segundos desde a
    /// época divididos por 60. Ver o comentário de fuso no topo do arquivo.
    private static func minuteOfDay(_ date: Date, calendar: Calendar) -> Int {
        calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
    }
}

// MARK: - Recibo

/// O retorno visível de "Colocar na agenda", no mesmo idioma da faixa de
/// resposta e do arraste da lista: "✓ nota · HH:MM" com um botão "Desfazer".
/// Ver `SwipeReceipt`, que é a mesma ideia para as ações de arraste.
public struct AgendaAddReceipt: Sendable, Hashable, Identifiable {
    public let id: UUID
    /// De qual mensagem: o leitor troca de mensagem sem fechar sozinho, e
    /// este campo é o que impede o recibo de uma mensagem aparecer colado na
    /// seguinte.
    public let messageID: String
    /// O `id` do `AgendaItem` criado — o que "Desfazer" apaga.
    public let itemID: String
    public let note: String

    public init(id: UUID = UUID(), messageID: String, itemID: String, note: String) {
        self.id = id
        self.messageID = messageID
        self.itemID = itemID
        self.note = note
    }

    /// "Na agenda — Call de contrato · qui 27, 15:00 · 14:32".
    ///
    /// `stamp` entra pronto porque formatar hora aqui reintroduziria a
    /// conversão de fuso que este arquivo inteiro existe para evitar.
    public static func note(eventLabel: String, stamp: String) -> String {
        "Na agenda — \(eventLabel) · \(stamp)"
    }
}
