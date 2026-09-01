import Foundation

/// A decisão de quem recebeu um convite: é o valor que vira `PARTSTAT` no
/// iTIP e o estado que o cartão volta a mostrar depois de entrar na fila.
public enum InviteRSVPResponse: String, Codable, Sendable, Hashable, CaseIterable {
    case accepted
    case tentative
    case declined

    public var partstat: String {
        switch self {
        case .accepted: "ACCEPTED"
        case .tentative: "TENTATIVE"
        case .declined: "DECLINED"
        }
    }

    public var label: String {
        switch self {
        case .accepted: "Aceito"
        case .tentative: "Talvez"
        case .declined: "Recusado"
        }
    }

    /// Texto de ação do botão. O estado usa particípio ("Aceito"), enquanto o
    /// controle precisa dizer o que acontecerá ao clique ("Aceitar").
    public var actionLabel: String {
        switch self {
        case .accepted: "Aceitar"
        case .tentative: "Talvez"
        case .declined: "Recusar"
        }
    }

    /// As outras duas decisões, na ordem da fila. Depois de Talvez sobram
    /// Aceitar e Recusar; depois de Aceitar sobem Talvez e Recusar.
    public var otherResponses: [InviteRSVPResponse] {
        Self.allCases.filter { $0 != self }
    }

    /// Aceitar e Talvez põem o compromisso na agenda. Recusar não.
    public var placesOnAgenda: Bool {
        self == .accepted || self == .tentative
    }
}

/// Onde uma resposta não pode ser produzida com segurança. Cada caso tem uma
/// frase de interface para que o cartão nunca ofereça um clique que não faz
/// nada.
public enum InviteRSVPUnavailableReason: Sendable, Hashable {
    case cancelled
    case accountMissing
    case organizerMissing
    case attendeeMissing
    case accountIsNotAttendee
    case accountIsOrganizer
    case eventIdentifierMissing
    case sendQueueMissing

    public var message: String {
        switch self {
        case .cancelled:
            "Este convite foi cancelado."
        case .accountMissing:
            "Não foi possível identificar a conta que recebeu o convite."
        case .organizerMissing:
            "Este convite não informa o organizador para receber a resposta."
        case .attendeeMissing:
            "Este convite não informa quem foi convidado."
        case .accountIsNotAttendee:
            "A conta que recebeu esta mensagem não aparece entre os convidados."
        case .accountIsOrganizer:
            "Você organizou este evento. Quem responde é quem foi convidado."
        case .eventIdentifierMissing:
            "Este convite não informa o identificador do evento para responder com segurança."
        case .sendQueueMissing:
            "A fila de saída não está disponível para enviar esta resposta."
        }
    }
}

/// O estado persistido de uma resposta. A identidade é por conta e UID do
/// evento; a mensagem é um fallback determinístico para a interface antes da
/// validação recusar um convite sem UID.
public struct InviteRSVPState: Sendable, Hashable {
    public let accountID: String
    public let eventKey: String
    public let response: InviteRSVPResponse

    public init(accountID: String, eventKey: String, response: InviteRSVPResponse) {
        self.accountID = accountID
        self.eventKey = eventKey
        self.response = response
    }
}

/// A mesma fila de saída usada pelo composer, com a persistência da resposta
/// na mesma transação. Não é um segundo transport: quem implementa esta porta
/// enfileira um `OutgoingMessage` no `outbox` existente.
public protocol InviteRSVPCommandPort: Sendable {
    func savedInviteRSVPStates() throws -> [InviteRSVPState]
    func queueInviteRSVP(_ message: OutgoingMessage, state: InviteRSVPState) throws
}

/// O retorno visível de uma ação de RSVP. `alreadyQueued` impede que o mesmo
/// botão pareça funcionar duas vezes quando a pessoa toca novamente.
public enum InviteRSVPResult: Sendable, Hashable {
    case queued(InviteRSVPResponse)
    case alreadyQueued(InviteRSVPResponse)
    case unavailable(InviteRSVPUnavailableReason)
    case failed
}

/// Regras puras para responder um `text/calendar` por iTIP.
public enum InviteRSVP {
    /// UID quando existe; a mensagem é o fallback determinístico de leitura
    /// para um convite malformado, que a validação depois mantém bloqueado.
    public static func eventKey(for invite: CalendarInvite, message: Message) -> String {
        if let uid = nonEmpty(invite.uid) { return "uid:\(uid)" }
        return "message:\(message.id)"
    }

    /// Não basta haver uma conta: ela precisa estar na lista de `ATTENDEE`.
    /// Responder como o primeiro convidado seria forjar a resposta de outra
    /// pessoa quando o convite chegou por encaminhamento ou lista de e-mail.
    public static func unavailableReason(
        for invite: CalendarInvite,
        account: Account?,
        canQueue: Bool
    ) -> InviteRSVPUnavailableReason? {
        guard !invite.isCancelled else { return .cancelled }
        guard let account, nonEmpty(account.address) != nil else { return .accountMissing }
        guard let organizer = invite.organizerContact, nonEmpty(organizer.address) != nil
        else { return .organizerMissing }
        guard !invite.attendeeContacts.isEmpty else { return .attendeeMissing }
        if !invite.attendeeContacts.contains(where: { sameAddress($0.address, account.address) }) {
            if let organizador = invite.organizerContact,
               sameAddress(organizador.address, account.address) {
                return .accountIsOrganizer
            }
            return .accountIsNotAttendee
        }
        guard nonEmpty(invite.uid) != nil else { return .eventIdentifierMissing }
        guard canQueue else { return .sendQueueMissing }
        return nil
    }

    /// Monta uma resposta RFC 5546. O conteúdo em calendário é separado do
    /// texto de cortesia para o transportador escolher `text/calendar` no MIME.
    public static func message(
        response: InviteRSVPResponse,
        invite: CalendarInvite,
        original: Message,
        account: Account,
        now: Date = Date()
    ) -> OutgoingMessage? {
        guard unavailableReason(for: invite, account: account, canQueue: true) == nil,
              let organizer = invite.organizerContact,
              let uid = nonEmpty(invite.uid)
        else { return nil }

        let attendee = OutgoingAddress(name: account.displayName, address: account.address)
        let originalID = nonEmpty(original.rfcMessageID)
        let references = uniqueReferences(original.references + (originalID.map { [$0] } ?? []))
        let title = invite.summary.isEmpty ? original.subject : invite.summary
        return OutgoingMessage(
            messageID: OutgoingMessage.newMessageID(for: account.address),
            accountID: account.id,
            from: attendee,
            to: [OutgoingAddress(organizer)],
            subject: "Resposta: \(title)",
            plainText: "Resposta ao convite \"\(title)\": \(response.label).",
            calendarICS: calendarBody(
                response: response, uid: uid, sequence: invite.sequence,
                organizer: organizer.address, attendee: account.address, now: now
            ),
            inReplyTo: originalID,
            references: references
        )
    }

    /// `METHOD:REPLY` e `PARTSTAT` são deliberadamente literais aqui: são o
    /// contrato iTIP que o teste guarda contra regressões de MIME ou rótulo.
    public static func calendarBody(
        response: InviteRSVPResponse,
        uid: String,
        sequence: Int?,
        organizer: String,
        attendee: String,
        now: Date
    ) -> String {
        var lines = [
            "BEGIN:VCALENDAR",
            "PRODID:-//OkamiUNI//PT-BR",
            "VERSION:2.0",
            "METHOD:REPLY",
            "BEGIN:VEVENT",
            "UID:\(clean(uid))",
            "DTSTAMP:\(timestamp(now))",
        ]
        if let sequence { lines.append("SEQUENCE:\(sequence)") }
        lines += [
            "ORGANIZER:mailto:\(clean(organizer))",
            "ATTENDEE;PARTSTAT=\(response.partstat):mailto:\(clean(attendee))",
            "END:VEVENT",
            "END:VCALENDAR",
        ]
        return lines.map(fold).joined(separator: "\r\n") + "\r\n"
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    private static func fold(_ line: String) -> String {
        var result = ""
        var length = 0
        for character in line {
            let width = String(character).utf8.count
            if length > 0, length + width > 75 {
                result += "\r\n "
                length = 1
            }
            result.append(character)
            length += width
        }
        return result
    }

    private static func clean(_ value: String) -> String {
        value.replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = clean(value)
        return clean.isEmpty ? nil : clean
    }

    private static func sameAddress(_ lhs: String, _ rhs: String) -> Bool {
        clean(lhs).caseInsensitiveCompare(clean(rhs)) == .orderedSame
    }

    private static func uniqueReferences(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { value in
            let clean = clean(value)
            return !clean.isEmpty && seen.insert(clean).inserted
        }
    }
}
