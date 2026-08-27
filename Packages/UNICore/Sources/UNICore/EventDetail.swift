import Foundation

/// Quem participa de um compromisso. Protótipo:
/// `P = (name, email, role, status) => ({ … })`.
public struct EventPerson: Sendable, Hashable, Identifiable {
    /// Como a pessoa respondeu ao convite. Protótipo: `'sim' | 'talvez' | qualquer`.
    public enum Status: String, Sendable, Hashable, CaseIterable {
        case yes = "sim"
        case maybe = "talvez"
        case pending = "aguardando"

        /// Protótipo: `p.status === 'sim' ? 'confirmou' : (p.status === 'talvez' ? 'talvez' : 'aguardando')`.
        public var label: String {
            switch self {
            case .yes: "confirmou"
            case .maybe: "talvez"
            case .pending: "aguardando"
            }
        }
    }

    public var id: String { address.lowercased() }
    public let name: String
    public let address: String
    /// "organizador", "obrigatório", "opcional", "você".
    public let role: String
    public let status: Status

    public init(name: String, address: String, role: String, status: Status) {
        self.name = name
        self.address = address
        self.role = role
        self.status = status
    }

    public var contact: Contact { Contact(name: name, address: address) }
    public var initials: String { contact.initials }

    /// A mesma pessoa com outro papel — o roster marca "· você" em quem é o dono da caixa.
    public func withRole(_ newRole: String) -> EventPerson {
        EventPerson(name: name, address: address, role: newRole, status: status)
    }
}

/// Uma linha de "O que gerou este compromisso".
public struct EventThreadEntry: Sendable, Hashable, Identifiable {
    /// Protótipo: `kind: 'email' | 'ia' | 'sistema'`. A cor do marcador sai daqui.
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case email
        case ai = "ia"
        case system = "sistema"
    }

    public var id: String { "\(when)|\(who)|\(what)" }
    public let when: String
    public let who: String
    public let what: String
    public let kind: Kind

    public init(when: String, who: String, what: String, kind: Kind) {
        self.when = when
        self.who = who
        self.what = what
        self.kind = kind
    }
}

/// Tudo que a tela 04 mostra além do que já está no `AgendaItem`.
/// Protótipo: `EV_DEFAULT` mesclado com `EV_META[title]`.
public struct EventDetail: Sendable, Hashable {
    public let place: String
    public let link: String?
    public let organizer: EventPerson
    public let people: [EventPerson]
    public let note: String
    public let recurrence: String
    public let notice: String
    public let agenda: [String]
    public let thread: [EventThreadEntry]

    public init(
        place: String, link: String?, organizer: EventPerson, people: [EventPerson],
        note: String, recurrence: String, notice: String,
        agenda: [String], thread: [EventThreadEntry]
    ) {
        self.place = place
        self.link = link
        self.organizer = organizer
        self.people = people
        self.note = note
        self.recurrence = recurrence
        self.notice = notice
        self.agenda = agenda
        self.thread = thread
    }

    /// A lista de participantes como o protótipo monta: o organizador primeiro,
    /// depois todo mundo que não seja ele, e quem for o dono da caixa ganha
    /// "· você" no papel — a não ser que o papel já diga isso.
    ///
    /// O endereço do dono é parâmetro, não constante: o app aceita qualquer
    /// conta, de qualquer domínio, e nada aqui pode presumir uma caixa fixa.
    public func guests(me: String) -> [EventPerson] {
        var roster = [organizer]
        for person in people where person.address.lowercased() != organizer.address.lowercased() {
            roster.append(person)
        }
        return roster.map { person in
            guard person.address.lowercased() == me.lowercased(),
                  !person.role.contains("você") else { return person }
            return person.withRole(person.role + " · você")
        }
    }

    /// Protótipo: `1 + people.filter(p => p.email !== organizer.email).length`.
    public var guestCount: Int {
        1 + people.filter { $0.address.lowercased() != organizer.address.lowercased() }.count
    }

    public var hasLink: Bool { link?.isEmpty == false }
    public var hasAgenda: Bool { !agenda.isEmpty }
    public var hasThread: Bool { !thread.isEmpty }
}
