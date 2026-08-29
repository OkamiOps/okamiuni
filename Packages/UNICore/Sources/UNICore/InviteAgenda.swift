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
        calendar: Calendar = .current,
        detail: EventDetail? = nil
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
            calendarUID: invite.uid, calendarSequence: invite.sequence,
            detail: detail
        )
    }

    /// O papel de quem foi convidado, na janela 04. Curto porque o `ATTENDEE`
    /// do iCalendar tem `ROLE` e `PARTSTAT` que este parser não lê de
    /// propósito — inventar "confirmou" a partir de nada seria pior que dizer
    /// "convidado".
    public static let papelConvidado = "convidado"
    public static let papelOrganizador = "organizador"

    /// Tudo o que a janela do compromisso mostra, tirado **do convite**.
    ///
    /// Local, link, organizador, participantes e descrição vêm do que o
    /// organizador mandou. A nota diz de onde o compromisso veio — era ela que
    /// dizia "Criado manualmente na agenda" num evento que ninguém criou à mão.
    ///
    /// `when` entra pronto (e não como `Date`) pelo mesmo motivo de
    /// `AgendaAddReceipt.note`: formatar data aqui reintroduziria a conversão
    /// de fuso que `DetectedEventConversion` inteiro existe para evitar.
    public static func detail(
        for invite: CalendarInvite,
        subject: String,
        sender: Contact,
        when: String,
        accountHost: String?
    ) -> EventDetail {
        let organizador = invite.organizerContact ?? sender
        let convidados = invite.attendeeContacts
            .filter { $0.id != organizador.id }
            .map { EventPerson(name: pessoaNome($0), address: $0.address, role: papelConvidado, status: .pending) }

        return EventDetail(
            // O `LOCATION` cru punha o cartão de entrada do Google Meet inteiro
            // na linha "LOCAL" — título, horário, fuso e o link que a janela já
            // mostra em cima. `EventPlace` deixa passar o endereço de verdade e
            // devolve `nil` quando o campo só trazia despejo.
            place: EventPlace.limpa(invite.location, summary: invite.summary) ?? EventPlace.semLocal,
            link: invite.meetingURL,
            organizer: EventPerson(
                name: pessoaNome(organizador), address: organizador.address,
                role: papelOrganizador, status: .yes
            ),
            people: convidados,
            note: nota(accountHost: accountHost),
            recurrence: "Evento único",
            // Não criamos alerta nenhum, e dizer "Alerta 10 min antes" seria a
            // janela prometendo um aviso que não vai tocar.
            notice: "Sem alerta",
            agenda: [],
            thread: [
                EventThreadEntry(when: when, who: pessoaNome(sender), what: subject, kind: .email)
            ],
            descricao: invite.descricao
        )
    }

    /// "Do convite por email · conta vantion". A conta entra porque a mesma
    /// reunião pode chegar em duas caixas da pessoa, e saber por qual delas ela
    /// entrou é metade da resposta a "de onde veio isto".
    public static func nota(accountHost: String?) -> String {
        guard let accountHost, !accountHost.isEmpty else { return "Do convite por email." }
        return "Do convite por email · conta \(accountHost)"
    }

    private static func pessoaNome(_ quem: Contact) -> String {
        quem.name.isEmpty ? quem.address : quem.name
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
            calendarSequence: proposed.calendarSequence ?? existing.calendarSequence,
            detail: proposed.detail ?? existing.detail
        )
    }

    /// Os dois compromissos dizem a mesma coisa sobre **quando** e **o quê**.
    /// O `id` e a conta ficam de fora de propósito: é o conteúdo que decide se
    /// há atualização a fazer.
    static func sameSchedule(_ a: AgendaItem, _ b: AgendaItem) -> Bool {
        guard a.title == b.title, a.startMinute == b.startMinute,
              a.endMinute == b.endMinute, a.dayOffset == b.dayOffset
        else { return false }
        return sameContent(a.detail, b.detail)
    }

    /// O que mais pode ter mudado num convite atualizado: a sala, o link, quem
    /// foi convidado, o texto.
    ///
    /// O `thread` fica **de fora**: ele guarda quando a mensagem chegou, e um
    /// encaminhamento chega noutra hora — comparar isso faria toda cópia de um
    /// convite pedir "Atualizar na agenda" sem nada ter mudado.
    ///
    /// Faltando o detalhe de um dos lados não há o que comparar (é o
    /// compromisso criado antes deste campo existir), e a resposta é "igual":
    /// inventar uma atualização ali mexeria num compromisso sem motivo.
    static func sameContent(_ a: EventDetail?, _ b: EventDetail?) -> Bool {
        guard let a, let b else { return true }
        return a.place == b.place && a.link == b.link && a.descricao == b.descricao
            && a.organizer == b.organizer && a.people == b.people
    }
}
