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

    /// Compromisso detectado no texto do email, sem `text/calendar`. O
    /// organizador é quem mandou, a conta é a caixa da mensagem — nunca o
    /// Ricardo Gomes das fixtures.
    public static func detail(
        from message: Message,
        accountHost: String?
    ) -> EventDetail {
        EventDetail(
            place: EventPlace.semLocal,
            link: nil,
            organizer: EventPerson(
                name: pessoaNome(message.from),
                address: message.from.address,
                role: papelOrganizador,
                status: .pending
            ),
            people: [],
            note: nota(accountHost: accountHost),
            recurrence: "Evento único",
            notice: "Sem alerta",
            agenda: [],
            thread: [
                EventThreadEntry(
                    when: message.receivedAt.formatted(
                        .dateTime.day().month(.abbreviated).hour().minute()
                    ),
                    who: pessoaNome(message.from),
                    what: message.subject,
                    kind: .email
                )
            ]
        )
    }

    /// Sem detalhe persistido e sem a mensagem de origem, ainda assim não
    /// inventamos a agenda de exemplo. A conta da caixa, se houver, é o
    /// único dado honesto que resta.
    public static func detailWithoutPrototype(account: Account?) -> EventDetail {
        let dono: EventPerson
        if let account {
            dono = EventPerson(
                name: account.displayName, address: account.address,
                role: "você", status: .yes
            )
        } else {
            dono = EventPerson(name: "", address: "", role: papelOrganizador, status: .pending)
        }
        return EventDetail(
            place: EventPlace.semLocal,
            link: nil,
            organizer: dono,
            people: [],
            note: nota(accountHost: account?.host),
            recurrence: "Evento único",
            notice: "Sem alerta",
            agenda: [],
            thread: []
        )
    }

    /// O que a janela 04 desenha: o detalhe gravado, ou o reconstruído da
    /// mensagem de origem, ou um vazio honesto. Compromisso de email/manual
    /// **nunca** cai em `Fixtures.eventDefault` — era assim que o veterinário
    /// da Odette abria com Ricardo Gomes e "Criado manualmente na agenda".
    public static func resolvedDetail(
        for item: AgendaItem,
        origin: Message?,
        account: Account?
    ) -> EventDetail {
        if let own = item.detail { return own }
        if let origin {
            return detail(from: origin, accountHost: account?.host)
        }
        if DetectedEventConversion.isFromEmail(item.id) || item.id.hasPrefix("manual-") {
            return detailWithoutPrototype(account: account)
        }
        return Fixtures.eventDetail(for: item.title)
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

    /// O compromisso que um evento **detectado no texto** já é, se houver.
    ///
    /// O `id` da mensagem é a guarda do segundo clique no mesmo cartão. O
    /// horário + título é a guarda do aviso do Calendar: outra mensagem, o
    /// mesmo "Luna - Dev time weekly" que o convite já gravou (ou que o
    /// EventKit já trouxe do Google Agenda).
    public static func existing(
        for event: DetectedEvent,
        messageID: String,
        accountID: String,
        referenceDay: Date,
        in agenda: [AgendaItem],
        calendar: Calendar = .current
    ) -> AgendaItem? {
        let id = DetectedEventConversion.agendaID(forMessageID: messageID)
        if let porID = agenda.first(where: { $0.id == id }) { return porID }
        let proposto = DetectedEventConversion.agendaItem(
            from: event, id: id, accountID: accountID,
            referenceDay: referenceDay, calendar: calendar
        )
        return existing(matching: proposto, in: agenda)
    }

    /// Casa título (sem caixa, sem acento) e começo no mesmo dia. A duração
    /// fica de fora: o texto do email às vezes omite o fim, o convite não.
    /// O sufixo " · qui 3, 01:00" que o analisador cola no rótulo também
    /// fica de fora — senão o aviso do Calendar nunca reencontraria o convite.
    static func existing(matching proposed: AgendaItem, in agenda: [AgendaItem]) -> AgendaItem? {
        agenda.first {
            $0.dayOffset == proposed.dayOffset
                && $0.startMinute == proposed.startMinute
                && sameEventTitle($0.title, proposed.title)
        }
    }

    static func sameEventTitle(_ a: String, _ b: String) -> Bool {
        let x = eventTitleKey(a)
        let y = eventTitleKey(b)
        return !x.isEmpty && x == y
    }

    static func eventTitleKey(_ title: String) -> String {
        let folded = title
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let cut = folded.range(of: " · ") {
            return String(folded[..<cut.lowerBound])
        }
        return folded
    }

    /// O compromisso que um `METHOD:CANCEL` deve tirar.
    ///
    /// Casa pelo `UID` **em qualquer conta**: o cancelamento chegou nesta
    /// caixa, mas o compromisso pode ter sido criado noutra, e o evento é o
    /// mesmo. Sem UID, cai no `id` da mensagem, como o caminho de sempre.
    public static func matchingCancellation(
        _ invite: CalendarInvite, messageID: String, in agenda: [AgendaItem],
        proposed: AgendaItem? = nil
    ) -> AgendaItem? {
        if let uid = invite.uid {
            if let porUID = agenda.first(where: {
                $0.calendarUID == uid || $0.id == uid || ($0.calendarUID?.contains(uid) == true)
            }) {
                return porUID
            }
        }
        if let proposed {
            let marca = proposed.cancellationFingerprint
            if let porHorario = agenda.first(where: {
                $0.cancellationFingerprint == marca && $0.dayOffset == proposed.dayOffset
            }) {
                return porHorario
            }
        }
        let id = DetectedEventConversion.agendaID(forMessageID: messageID)
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
            detail: proposed.detail ?? existing.detail,
            calendarID: proposed.calendarID ?? existing.calendarID,
            calendarTitle: proposed.calendarTitle ?? existing.calendarTitle,
            calendarColorHex: proposed.calendarColorHex ?? existing.calendarColorHex,
            calendarSource: proposed.calendarSource ?? existing.calendarSource,
            isCancelled: existing.isCancelled || proposed.isCancelled
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

    /// A mesma reunião, vista de origens diferentes.
    ///
    /// O EventKit, o convite por email e o "Colocar na agenda" geram `id`
    /// distintos para o mesmo horário. Sem isto, a grade mostra cinco blocos
    /// idênticos no mesmo minuto — e a pessoa trata cada um como um
    /// compromisso.
    ///
    /// Casa pelo `UID` no **mesmo dia** (o evento que mudou de hora continua
    /// sendo um), ou pelo título+começo+fim+dia quando o UID não atravessa as
    /// origens.
    public static func sameMeeting(_ a: AgendaItem, _ b: AgendaItem) -> Bool {
        if let ua = normalizedUID(a.calendarUID), let ub = normalizedUID(b.calendarUID),
           ua == ub, a.dayOffset == b.dayOffset
        {
            return true
        }
        return eventTitleKey(a.title) == eventTitleKey(b.title)
            && a.startMinute == b.startMinute
            && a.endMinute == b.endMinute
            && a.dayOffset == b.dayOffset
    }

    /// Cinco cópias viram uma. A ordem de chegada se mantém; de cada grupo
    /// sobra o compromisso mais informativo (EventKit, UID, SEQUENCE, detalhe).
    ///
    /// **Linear no tamanho da agenda.** Comparar cada par era o que travava a
    /// troca de semana: o EventKit traz meses de ocorrências, e a grade pedia
    /// esta lista várias vezes por quadro.
    public static func coalesce(_ items: [AgendaItem]) -> [AgendaItem] {
        guard items.count > 1 else { return items }
        var parent = Array(items.indices)
        func find(_ i: Int) -> Int {
            var x = i
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }
        func union(_ i: Int, _ j: Int) {
            let a = find(i), b = find(j)
            if a != b { parent[b] = a }
        }
        var bySlot: [String: Int] = [:]
        var byUID: [String: Int] = [:]
        bySlot.reserveCapacity(items.count)
        byUID.reserveCapacity(items.count)
        for i in items.indices {
            let item = items[i]
            let slot = slotIdentity(item)
            if let visto = bySlot[slot] {
                union(i, visto)
            } else {
                bySlot[slot] = i
            }
            if let uid = uidIdentity(item) {
                if let visto = byUID[uid] {
                    union(i, visto)
                } else {
                    byUID[uid] = i
                }
            }
        }
        var groups: [Int: [AgendaItem]] = [:]
        var order: [Int] = []
        groups.reserveCapacity(bySlot.count)
        order.reserveCapacity(bySlot.count)
        for i in items.indices {
            let root = find(i)
            if groups[root] == nil { order.append(root) }
            groups[root, default: []].append(items[i])
        }
        return order.map { pickSurvivor(groups[$0]!) }
    }

    static func slotIdentity(_ item: AgendaItem) -> String {
        "\(eventTitleKey(item.title))|\(item.dayOffset)|\(item.startMinute)|\(item.endMinute)"
    }

    static func uidIdentity(_ item: AgendaItem) -> String? {
        guard let uid = normalizedUID(item.calendarUID) else { return nil }
        return "\(uid)|\(item.dayOffset)"
    }

    static func pickSurvivor(_ group: [AgendaItem]) -> AgendaItem {
        guard group.count > 1 else { return group[0] }
        return group.max(by: { survivorRank($0) < survivorRank($1) }) ?? group[0]
    }

    /// Ativo ganha de cancelado; calendário do sistema ganha do email; UID e
    /// versão desempata; o detalhe mais cheio fica.
    static func survivorRank(_ item: AgendaItem) -> (Int, Int, Int, Int, Int) {
        let detalhe = item.detail
        let pesoDetalhe = (detalhe?.people.count ?? 0)
            + (detalhe?.link == nil ? 0 : 2)
            + (detalhe?.descricao == nil ? 0 : 2)
        return (
            item.isCancelled ? 0 : 1,
            item.calendarID == nil ? 0 : 1,
            item.calendarUID == nil ? 0 : 1,
            item.calendarSequence ?? 0,
            pesoDetalhe
        )
    }

    static func normalizedUID(_ uid: String?) -> String? {
        guard let uid else { return nil }
        let podado = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        return podado.isEmpty ? nil : podado
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
