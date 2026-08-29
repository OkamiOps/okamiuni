import Foundation

/// O que o cartão do convite tem a oferecer sobre a agenda, **agora**.
///
/// Três estados, e o defeito era não ter nenhum: o botão dizia sempre "Colocar
/// na agenda", e clicar sempre criava. O dono recebeu o convite do DreamSquad e
/// depois o "Convite atualizado" do mesmo evento, clicou nos dois, e ficou com
/// dois blocos idênticos na agenda.
public enum InviteAgendaState: Sendable, Hashable {
    /// Este evento não está na agenda: "Colocar na agenda".
    case ausente
    /// Já está, e igualzinho: "✓ Na agenda". É o estado do encaminhamento e
    /// da segunda cópia do mesmo convite — o cartão diz que não há o que fazer
    /// **ao abrir a mensagem**, e não só depois de um clique que duplicaria.
    case naAgenda
    /// Já está, mas o convite na tela é mais novo (ou diz outra coisa):
    /// "Atualizar na agenda". Atualiza o que existe; nunca cria um segundo.
    case desatualizado
}

/// As regras puras entre um convite e a agenda: identidade, versão e
/// atualização. Mora em `UNICore` pelo motivo de sempre — é regra, e uma
/// `View` é `@MainActor` implícito no Swift 6.
public enum InviteAgenda {

    /// O compromisso que este convite pede, com a identidade do iCalendar
    /// pendurada nele. `nil` sem `DTSTART`, como `CalendarInvite.detectedEvent`.
    public static func item(
        for invite: CalendarInvite,
        id: String,
        accountID: String,
        referenceDay: Date,
        calendar: Calendar = .current
    ) -> AgendaItem? {
        guard let evento = invite.detectedEvent else { return nil }
        let base = DetectedEventConversion.agendaItem(
            from: evento, id: id, accountID: accountID,
            referenceDay: referenceDay, calendar: calendar
        )
        return AgendaItem(
            id: base.id, title: base.title,
            startMinute: base.startMinute, endMinute: base.endMinute,
            accountID: base.accountID, dayOffset: base.dayOffset,
            calendarUID: invite.uid, calendarSequence: invite.sequence
        )
    }

    /// O compromisso que já está na agenda para **este** convite, se houver.
    ///
    /// Casa pelo `UID` dentro da conta: é a identidade que atravessa cópias, e
    /// é por ela que o "Convite atualizado" reencontra o que o original criou.
    /// A conta entra na conta porque o mesmo evento pode legitimamente estar em
    /// duas contas da pessoa, e cada agenda é da sua.
    ///
    /// Sem `UID`, cai no `id` — a identidade de antes, derivada da mensagem.
    public static func existing(
        for invite: CalendarInvite, id: String, accountID: String, in agenda: [AgendaItem]
    ) -> AgendaItem? {
        if let uid = invite.uid {
            if let porUID = agenda.first(where: { $0.calendarUID == uid && $0.accountID == accountID }) {
                return porUID
            }
        }
        return agenda.first { $0.id == id }
    }

    /// O que o cartão deve oferecer.
    ///
    /// `SEQUENCE` maior manda: é o que o organizador diz ser mais novo. Sem
    /// `SEQUENCE` maior, ainda vale comparar o que o compromisso mostra — há
    /// quem mande alteração sem mexer na versão, e uma reunião que mudou de
    /// horário não pode ficar com o horário velho na agenda por causa disso.
    /// Igual em versão e em conteúdo é "Na agenda", que é o caso do
    /// encaminhamento.
    public static func state(
        for invite: CalendarInvite, existing: AgendaItem?, proposed: AgendaItem?
    ) -> InviteAgendaState {
        guard let existing else { return .ausente }
        guard let proposed else { return .naAgenda }
        if (invite.sequence ?? 0) > (existing.calendarSequence ?? 0) { return .desatualizado }
        return sameSchedule(proposed, existing) ? .naAgenda : .desatualizado
    }

    /// O convite novo entrando **no compromisso que já existe**: horário,
    /// título, dia e versão passam a ser os do convite; o `id` continua sendo o
    /// que a agenda já conhece.
    ///
    /// O `id` é o que "Desfazer", "Tirar da agenda" e "Ir para o email de
    /// origem" seguram. Trocá-lo por causa de uma atualização faria o
    /// compromisso mudar de identidade no meio da vida — e a mensagem que o
    /// gerou deixaria de ser alcançável.
    public static func updated(_ existing: AgendaItem, with proposed: AgendaItem) -> AgendaItem {
        AgendaItem(
            id: existing.id, title: proposed.title,
            startMinute: proposed.startMinute, endMinute: proposed.endMinute,
            accountID: existing.accountID, dayOffset: proposed.dayOffset,
            calendarUID: proposed.calendarUID ?? existing.calendarUID,
            calendarSequence: proposed.calendarSequence ?? existing.calendarSequence
        )
    }

    /// Os dois compromissos dizem a mesma coisa sobre **quando** e **o quê**.
    /// O `id` e a conta ficam de fora de propósito: é o conteúdo que decide se
    /// há atualização a fazer.
    static func sameSchedule(_ a: AgendaItem, _ b: AgendaItem) -> Bool {
        a.title == b.title && a.startMinute == b.startMinute
            && a.endMinute == b.endMinute && a.dayOffset == b.dayOffset
    }
}
