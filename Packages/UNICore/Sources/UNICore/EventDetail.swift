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
            case .yes: L10n.tr("confirmou")
            case .maybe: L10n.tr("talvez")
            case .pending: L10n.tr("aguardando")
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

    /// A `DESCRIPTION` do convite, inteira, quando o compromisso veio de um.
    ///
    /// É o texto que o organizador escreveu — pauta, instruções, o link
    /// repetido. A janela mostrava a pauta de fixture e nunca isto. Aditivo
    /// (`nil` em todo compromisso que não veio de convite).
    public let descricao: String?

    public init(
        place: String, link: String?, organizer: EventPerson, people: [EventPerson],
        note: String, recurrence: String, notice: String,
        agenda: [String], thread: [EventThreadEntry],
        descricao: String? = nil
    ) {
        self.descricao = descricao
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

    /// A sala efetiva do compromisso.
    ///
    /// O Calendar do macOS nem sempre preenche `EKEvent.url`: convites do
    /// Google frequentemente guardam o Meet em `notes`, e alguns provedores o
    /// repetem em `LOCATION`. A janela, o menu e o encaminhamento precisam
    /// fazer a mesma pergunta, por isso a resolução mora no modelo.
    public var meetingLink: String? {
        // `link` veio de um campo/propiedade explícita e pode ser de qualquer
        // serviço. Local e descrição são texto livre, então continuam sob a
        // allowlist de `MeetingLink.first(in:)`.
        if let link, let explicit = MeetingLink.normalizado(link) { return explicit }
        for text in [place, descricao].compactMap({ $0 }) {
            if let found = MeetingLink.first(in: text) { return found }
        }
        return nil
    }

    /// Descrição útil para leitura, sem o cartão automático da videoconferência.
    ///
    /// O Google anexa um bloco delimitado por `-::~:~:` contendo o mesmo link,
    /// ajuda e “Não edite esta seção”. Esse bloco vira cartão + ação “Entrar”;
    /// repeti-lo como descrição só cria ruído. Fora dele, removemos apenas a
    /// linha que contém exatamente a sala promovida e preservamos a pauta.
    public var visibleDescription: String? {
        Self.cleanDescription(descricao, meetingLink: meetingLink)
    }

    public static func cleanDescription(
        _ description: String?, meetingLink: String?
    ) -> String? {
        guard let description else { return nil }
        let normalized = description
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.components(separatedBy: "\n")

        // O bloco gerado pelo Google é sempre apêndice. Preservamos tudo que
        // veio antes do primeiro delimitador e descartamos somente o apêndice.
        if let boundary = lines.firstIndex(where: { $0.contains("-::~:~:") }) {
            lines.removeSubrange(boundary...)
        }

        lines = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()
            if let meetingLink, trimmed.contains(meetingLink) { return false }
            if lower.contains("support.google.com/a/users/answer/9282720") { return false }
            if lower.contains("não edite esta seção") || lower.contains("do not edit this section") {
                return false
            }
            return true
        }

        while lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            lines.removeFirst()
        }
        while lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            lines.removeLast()
        }

        var compacted: [String] = []
        for line in lines {
            let blank = line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if blank, compacted.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                continue
            }
            compacted.append(line)
        }
        let visible = compacted.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return visible.isEmpty ? nil : visible
    }

    public var hasLink: Bool { meetingLink != nil }
    public var hasAgenda: Bool { !agenda.isEmpty }
    public var hasThread: Bool { !thread.isEmpty }
}
