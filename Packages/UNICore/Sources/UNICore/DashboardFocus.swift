import Foundation

/// O recorte de prioridades da aba Dashboard.
///
/// A Caixa e a Agenda continuam sendo o lugar do detalhe. Aqui entra só o
/// que pede a pessoa agora: e-mail com ação, o que ainda resta hoje na
/// agenda, as pendências que o texto já detectou. A ordem é heurística —
/// etiquetas, sinalização, leitura, categoria — para a aba abrir cheia
/// sem gastar uma ida à IA. O briefing em linguagem fica a um clique.
public struct DashboardFocus: Sendable, Hashable {

    public static let mailLimit = 7
    public static let meetingLimit = 8
    public static let pendingLimit = 6
    /// Teto da varredura: a aba não pode ranquear a caixa inteira. Os 300
    /// mais recentes da triagem bastam para o recorte, e é o que impede o
    /// freeze na primeira abertura.
    public static let candidateCap = 300

    /// Por que esta mensagem sobreviveu ao filtro. Um rótulo só: o motivo
    /// mais forte, não a soma. A tela escreve isto ao lado do remetente.
    public enum Reason: String, Sendable, Hashable {
        case needsReply
        case lead
        case deadline
        case flagged
        case unread
        case today

        public var label: String {
            switch self {
            case .needsReply: "Precisa resposta"
            case .lead: "Lead"
            case .deadline: "Prazo"
            case .flagged: "Sinalizado"
            case .unread: "Não lido"
            case .today: "Hoje"
            }
        }

        /// Alta é o que trava o dia: resposta, prazo, lead.
        public var isUrgent: Bool {
            switch self {
            case .needsReply, .lead, .deadline: true
            case .flagged, .unread, .today: false
            }
        }

        public var rankLabel: String { isUrgent ? "Alta" : "Média" }
    }

    public struct MailItem: Sendable, Hashable, Identifiable {
        public var id: String { message.id }
        public let message: Message
        public let reason: Reason

        public init(message: Message, reason: Reason) {
            self.message = message
            self.reason = reason
        }
    }

    public let mail: [MailItem]
    public let meetings: [AgendaItem]
    public let pending: [PendingItem]
    /// Quantas mensagens ranqueadas ficaram fora do teto. A tela aponta
    /// para a Caixa em vez de alongar a lista.
    public let omittedMailCount: Int
    public let omittedMeetingCount: Int
    public let nextUpLabel: String

    public init(
        mail: [MailItem],
        meetings: [AgendaItem],
        pending: [PendingItem],
        omittedMailCount: Int,
        omittedMeetingCount: Int,
        nextUpLabel: String
    ) {
        self.mail = mail
        self.meetings = meetings
        self.pending = pending
        self.omittedMailCount = omittedMailCount
        self.omittedMeetingCount = omittedMeetingCount
        self.nextUpLabel = nextUpLabel
    }

    /// Recorte síncrono, puro, sem relógio escondido. `nowMinute` e o
    /// recorte de conta entram pela porta — a aba e o teste passam os
    /// mesmos valores que a Caixa já usa.
    public static func snapshot(
        messages: [Message],
        agenda: [AgendaItem],
        pending: [PendingItem],
        nowMinute: Int,
        accountID: String? = nil,
        /// O instante de referência do prazo. Entra pela porta, como
        /// `nowMinute`: a triagem mede "faltam 12 h" contra ele, e um relógio
        /// escondido aqui faria o teste do prazo depender do dia em que roda.
        now: Date = Date()
    ) -> DashboardFocus {
        let scopedMessages = accountID.map { id in messages.filter { $0.accountID == id } } ?? messages
        let scopedAgenda = accountID.map { id in agenda.filter { $0.accountID == id } } ?? agenda
        let scopedPending = accountID.map { id in pending.filter { $0.accountID == id } } ?? pending

        var ranked: [Ranked] = []
        var fallback: [Ranked] = []
        ranked.reserveCapacity(mailLimit)
        fallback.reserveCapacity(mailLimit)
        var scanned = 0
        for message in scopedMessages {
            switch message.bucket {
            case .junk, .trash, .drafts, .sent:
                continue
            case .today, .later, .all, .archived:
                break
            }
            scanned += 1
            if let hit = rank(message, now: now) {
                ranked.append(hit)
            } else if fallback.count < mailLimit, let hit = todayFallback(message) {
                fallback.append(hit)
            }
            if scanned >= candidateCap { break }
        }
        ranked.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.item.message.receivedAt > b.item.message.receivedAt
        }
        if ranked.isEmpty { ranked = fallback }
        let mail = Array(ranked.prefix(mailLimit).map(\.item))

        let upcoming = scopedAgenda
            .filter { item in
                guard !item.isCancelled else { return false }
                if item.dayOffset > 0 { return true }
                if item.dayOffset == 0 { return item.endMinute > nowMinute }
                return false
            }
            .sorted { a, b in
                if a.dayOffset != b.dayOffset { return a.dayOffset < b.dayOffset }
                return a.startMinute < b.startMinute
            }
        let meetings = Array(upcoming.prefix(meetingLimit))

        return DashboardFocus(
            mail: mail,
            meetings: meetings,
            pending: Array(scopedPending.prefix(pendingLimit)),
            omittedMailCount: max(0, ranked.count - mailLimit),
            omittedMeetingCount: max(0, upcoming.count - meetingLimit),
            nextUpLabel: AgendaSummary.nextUpLabel(for: scopedAgenda.filter { $0.dayOffset == 0 }, now: nowMinute)
        )
    }

    /// Rótulo do dia do compromisso na coluna de próximos.
    public static func meetingDayName(offset: Int, anchor: Date) -> String {
        DayLabel.name(forOffset: offset)
            ?? MonthAgenda.shortDayLabel(dayOffset: offset, anchor: anchor)
    }

    /// Primeiro nome. Endereço no `displayName` não vale — a tela escrevia
    /// "Bom dia, marcos@okamiops.com".
    public static func personName(displayName: String?, address: String?) -> String? {
        if let raw = displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty, !raw.contains("@") {
            return raw.split(whereSeparator: \.isWhitespace).first.map(String.init)
        }
        guard let local = address?.split(separator: "@").first, local.count > 1 else {
            return nil
        }
        let piece = String(local)
        return piece.prefix(1).uppercased() + piece.dropFirst()
    }

    /// "Bom dia, Marcos" — o primeiro nome da conta, se houver.
    public static func greeting(nowMinute: Int, name: String?) -> String {
        let hello: String
        switch nowMinute {
        case ..<720: hello = "Bom dia"
        case ..<1080: hello = "Boa tarde"
        default: hello = "Boa noite"
        }
        let first = name?
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init)
        if let first, !first.isEmpty, !first.contains("@") {
            return "\(hello), \(first)"
        }
        return hello
    }

    public static func greeting(
        nowMinute: Int, displayName: String?, address: String?
    ) -> String {
        greeting(nowMinute: nowMinute, name: personName(displayName: displayName, address: address))
    }

    // MARK: - Ranking

    private struct Ranked {
        let item: MailItem
        let score: Int
    }

    /// `nil` é "isto não pede a pessoa agora". Promoções e redes só passam
    /// se já tiverem sido sinalizadas ou marcadas como resposta — o filtro
    /// não esconde um follow-up que a pessoa mesma marcou.
    private static func rank(_ message: Message, now: Date) -> Ranked? {
        switch message.bucket {
        case .junk, .trash, .drafts, .sent:
            return nil
        case .today, .later, .all, .archived:
            break
        }

        // A triagem, quando existe, substitui **quatro** coisas: os três
        // sinais de etiqueta e a leitura de ruído de fundo. `isPromoOrSocial`
        // — a heurística que lê `category` e caça a palavra "newsletter" no
        // remetente e no assunto — deixa de valer para a mensagem triada, e
        // quem responde "isto é ruído?" passa a ser `intent`. É de propósito:
        // um modelo que leu o email inteiro sabe melhor do que uma busca por
        // substring, e manter as duas faria a mensagem de um cliente chamado
        // "Newsletter Ltda." sumir do dashboard apesar de a triagem dizer que
        // é um lead. Estrela, leitura e caixa continuam sendo estado da
        // mensagem, não juízo do modelo, e valem para as duas fontes.
        let sinais = message.triage.map { triageSignals($0, now: now) }
            ?? tagSignals(message)

        // Ruído de fundo é o que ninguém marcou: a newsletter e o recibo
        // saem, mas a estrela da pessoa e um "precisa resposta" os trazem de
        // volta — o filtro não pode esconder o que ela mesma sinalizou.
        if sinais.isBackgroundNoise {
            guard message.isFlagged || sinais.needsReply else { return nil }
        }

        var score = sinais.score
        var reason: Reason? = sinais.reason
        if message.isFlagged {
            score += 50
            reason = reason ?? .flagged
        }
        if !message.isRead {
            score += 30
            reason = reason ?? .unread
        }

        switch message.bucket {
        case .today:
            score += 20
        case .later, .all:
            score += 10
        case .archived:
            // Arquivo só entra com ação (resposta, lead, prazo, estrela).
            // Não lido sozinho é ruído de recibo.
            if reason == nil || reason == .unread { return nil }
        case .junk, .trash, .drafts, .sent:
            return nil
        }

        guard let reason, score > 0 else { return nil }
        return Ranked(
            item: MailItem(message: message.withoutHeavyPayload(), reason: reason),
            score: score
        )
    }

    /// O que sobrou dos três sinais fortes: quanto vale e qual é o motivo.
    /// Um tipo só para as duas fontes porque o resto do ranking não pode
    /// saber de qual delas o número veio — a spec é explícita que a origem
    /// não aparece na tela, e `Reason` não ganha caso novo.
    private struct Signals {
        var score: Int
        var reason: Reason?
        var needsReply: Bool
        var isBackgroundNoise: Bool
    }

    /// A heurística de sempre, para quem ainda não foi analisado. Numa conta
    /// de verdade ela quase nunca acha nada — as etiquetas do protótipo não
    /// existem lá —, e é justamente por isso que a triagem existe.
    private static func tagSignals(_ message: Message) -> Signals {
        let needsReply = hasTag(message, "Precisa resposta")
        var signals = Signals(
            score: 0, reason: nil, needsReply: needsReply,
            isBackgroundNoise: isPromoOrSocial(message)
        )
        if needsReply {
            signals.score += 100
            signals.reason = .needsReply
        }
        if hasTag(message, "Lead") {
            signals.score += 80
            signals.reason = signals.reason ?? .lead
        }
        if hasTag(message, "Prazo") {
            signals.score += 70
            signals.reason = signals.reason ?? .deadline
        }
        return signals
    }

    /// A mesma escala, agora com o que a análise afirmou. O prazo pesa pela
    /// distância: o que vence hoje vale mais do que o que vence na semana que
    /// vem, e sem isso "Prazo" seria um rótulo sem hierarquia nenhuma.
    private static func triageSignals(_ triage: MessageTriage, now: Date) -> Signals {
        var signals = Signals(
            score: 0, reason: nil, needsReply: triage.needsReply,
            isBackgroundNoise: triage.intent.isBackgroundNoise
        )
        if triage.needsReply {
            signals.score += 100
            signals.reason = .needsReply
        }
        if triage.intent == .lead {
            signals.score += 80
            signals.reason = signals.reason ?? .lead
        }
        if let deadline = triage.deadline {
            signals.score += deadlineWeight(deadline.date, now: now)
            signals.reason = signals.reason ?? .deadline
        }
        // Urgência é peso, não motivo: ela desempata duas mensagens do mesmo
        // tipo sem inventar um sétimo caso de `Reason` para a tela escrever.
        if triage.urgency == .high {
            signals.score += 20
        }
        return signals
    }

    /// 70 até 24 h, 50 até 72 h, 30 depois. Um prazo já vencido conta como o
    /// mais próximo possível — ele é o que mais pede a pessoa agora.
    static func deadlineWeight(_ deadline: Date, now: Date) -> Int {
        let horas = deadline.timeIntervalSince(now) / 3_600
        if horas <= 24 { return 70 }
        if horas <= 72 { return 50 }
        return 30
    }

    private static func todayFallback(_ message: Message) -> Ranked? {
        switch message.bucket {
        case .today:
            break
        case .later, .all, .archived, .junk, .trash, .drafts, .sent:
            return nil
        }
        if isPromoOrSocial(message) { return nil }
        let reason: Reason = message.isRead ? .today : .unread
        return Ranked(
            item: MailItem(message: message.withoutHeavyPayload(), reason: reason),
            score: message.isRead ? 5 : 15
        )
    }

    private static func hasTag(_ message: Message, _ name: String) -> Bool {
        message.tags.contains { $0.name == name }
    }

    /// Sem `MailCategory.resolve`: ele faz folding e regex em cada mensagem,
    /// e era isso que congelava a aba com a caixa real.
    private static func isPromoOrSocial(_ message: Message) -> Bool {
        switch message.category {
        case .promotions, .social: return true
        default: break
        }
        let from = message.from.name.lowercased()
        if from.contains("newsletter") { return true }
        let subject = message.subject.lowercased()
        return subject.contains("newsletter")
    }
}
