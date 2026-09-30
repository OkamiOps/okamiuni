import Foundation

/// O recorte de prioridades da aba Dashboard.
///
/// A Caixa e a Agenda continuam sendo o lugar do detalhe. Aqui entra só o
/// que pede a pessoa agora: e-mail com ação, o que ainda resta hoje na
/// agenda, as pendências que o texto já detectou. A ordem é heurística —
/// etiquetas, sinalização, leitura, categoria — sobre ações atuais. Uma
/// lista vazia é preferível a promover avisos antigos para preencher a aba.
public struct DashboardFocus: Sendable, Hashable {

    public static let mailLimit = 7
    public static let meetingLimit = 8
    public static let pendingLimit = 6
    /// Teto da varredura: a aba não pode ranquear a caixa inteira. Os 300
    /// mais recentes da triagem bastam para o recorte, e é o que impede o
    /// freeze na primeira abertura.
    public static let candidateCap = 300
    /// Sem uma estrela ou uma data atual, uma análise antiga não prova que
    /// a pessoa ainda precisa agir. A mensagem continua disponível na Caixa.
    public static let freshnessDays = 7

    /// Decisões da pessoa e estado confirmado vêm antes da classificação por IA.
    public static func isActiveCandidate(_ message: Message) -> Bool {
        guard message.bucket == .today || message.bucket == .all else { return false }
        // Registros Gmail legados sem rótulos precisam ser reconciliados antes
        // de virarem uma cobrança. A sincronização revalida esses metadados.
        if message.id.hasPrefix(message.accountID + ":g:"), message.folderIDs.isEmpty { return false }
        return true
    }

    /// O mesmo recorte para o ranking, a seleção anterior ao teto e o contexto
    /// da IA. Arquivar/adiar vence qualquer análise; a estrela preserva uma
    /// pendência antiga que a pessoa explicitamente quis manter.
    public static func isRelevantCandidate(_ message: Message, now: Date) -> Bool {
        guard isActiveCandidate(message) else { return false }
        if message.isFlagged { return true }
        guard !hasClosedInvitation(message, now: now) else { return false }
        return isRecent(message, now: now) || relevantDeadline(for: message, now: now) != nil
    }

    /// Data que ainda ajuda a organizar esta semana. Uma fonte antiga pode
    /// anunciar um vencimento futuro; um vencimento passado só sobrevive com
    /// um pedido recebido recentemente, sem inferir pagamento ou resolução.
    public static func relevantDeadline(for message: Message, now: Date) -> DetectedDeadline? {
        guard let deadline = message.triage?.deadline,
              !hasClosedInvitation(message, now: now) else { return nil }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: freshnessDays + 1, to: today)!
        guard deadline.date < end else { return nil }
        if deadline.date >= today { return deadline }
        // Uma data num aviso de encerramento, feedback ou recibo não prova
        // ação pendente. Só pedidos ou uma necessidade de resposta que o
        // cabeçalho não desmentiu podem ser apresentados como atraso.
        guard let triage = message.triage,
              triage.intent == .request || triage.barred(byBulk: message.effectiveBulkMarks).needsReply
        else { return nil }
        let oldest = calendar.date(byAdding: .day, value: -freshnessDays, to: today)!
        return isRecent(message, now: now) && deadline.date >= oldest ? deadline : nil
    }

    static func isRecent(_ message: Message, now: Date) -> Bool {
        let calendar = Calendar.current
        let oldest = calendar.date(byAdding: .day, value: -freshnessDays,
                                   to: calendar.startOfDay(for: now))!
        return message.receivedAt >= oldest && message.receivedAt <= now.addingTimeInterval(300)
    }

    /// Datas e cancelamento do convite são fatos; `needsReply` não pode
    /// transformar um encontro encerrado num trabalho pendente.
    static func hasClosedInvitation(_ message: Message, now: Date) -> Bool {
        if let ics = message.calendarICS, let invite = ICalendar.parse(ics) {
            if invite.isCancelled { return true }
            // O parser lê a primeira ocorrência, não a expansão da série.
            // Seu fim não prova que uma reunião recorrente foi encerrada.
            if ics.split(whereSeparator: \.isNewline).contains(where: {
                let line = $0.uppercased()
                return line.hasPrefix("RRULE:") || line.hasPrefix("RRULE;")
            }) { return false }
            if let event = invite.detectedEvent, event.end <= now { return true }
        }
        guard message.triage?.intent == .scheduling else { return false }
        if let event = message.detectedEvent, event.end <= now { return true }
        if let deadline = message.triage?.deadline,
           deadline.date < Calendar.current.startOfDay(for: now) { return true }
        return false
    }

    /// Por que esta mensagem sobreviveu ao filtro. Um rótulo só: o motivo
    /// mais forte, não a soma. A tela escreve isto ao lado do remetente.
    public enum Reason: String, Sendable, Hashable {
        case needsReply
        case lead
        case deadline
        case flagged
        /// Disparo em massa que ainda assim apareceu — porque a pessoa o
        /// sinalizou, ou porque a coluna estava vazia sem ele.
        ///
        /// Caso próprio, e não `.unread`, porque é a resposta à queixa: sete
        /// linhas com a mesma etiqueta não dizem nada, e a diferença que mais
        /// importa em dois segundos é entre gente falando comigo e máquina
        /// falando com uma lista. "Não lido" não conta essa diferença.
        case broadcast
        case unread
        case today

        public var label: String {
            switch self {
            case .needsReply: L10n.tr("Precisa resposta")
            case .lead: L10n.tr("Lead")
            case .deadline: L10n.tr("Prazo")
            case .flagged: L10n.tr("Sinalizado")
            case .broadcast: L10n.tr("Disparo")
            case .unread: L10n.tr("Não lido")
            case .today: L10n.tr("Hoje")
            }
        }

        /// Alta é o que trava o dia: resposta, prazo, lead.
        public var isUrgent: Bool {
            switch self {
            case .needsReply, .lead, .deadline: true
            case .flagged, .broadcast, .unread, .today: false
            }
        }

        public var rankLabel: String { isUrgent ? L10n.tr("Alta") : L10n.tr("Média") }
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
    /// Quantas mensagens a triagem **descartou** por não pedirem a pessoa —
    /// newsletter, recibo, aviso.
    ///
    /// É outro número que `omittedMailCount`: aquele conta o que ranqueou e
    /// não coube no teto de sete (o "+ N na Caixa" do rodapé), este conta o
    /// que nem chegou a ranquear (o "N fora da lista · newsletters e avisos"
    /// da faixa HOJE). Sem os dois, a faixa diria que a caixa tem só o que
    /// está na lista.
    public let discardedMailCount: Int
    /// Quantos **disparos** o recorte varreu e não mostrou.
    ///
    /// É o número que faz o filtro do 08 escrever "Disparos 13" em vez de
    /// "Disparos 2": as linhas de disparo que sobreviveram são poucas por
    /// construção (o teto é sete linhas no total), e sem esta contagem o
    /// número ao lado do botão diria quanto **coube**, não quanto **existe** —
    /// e religar o filtro sabendo quantos são é justamente o ponto dele.
    ///
    /// Não é um pedaço de `discardedMailCount`: aquele conta o que a triagem
    /// jogou fora por não pedir a pessoa (newsletter, recibo), este conta o
    /// que o **cabeçalho** denunciou como envio em massa. Uma mensagem pode
    /// ser as duas coisas, e por isso os dois números não se somam sem
    /// pensar — `DayPlan` os manda para categorias diferentes.
    public let discardedBroadcastCount: Int
    public let omittedMeetingCount: Int
    public let nextUpLabel: String

    public init(
        mail: [MailItem],
        meetings: [AgendaItem],
        pending: [PendingItem],
        omittedMailCount: Int,
        omittedMeetingCount: Int,
        nextUpLabel: String,
        discardedMailCount: Int = 0,
        discardedBroadcastCount: Int = 0
    ) {
        self.discardedBroadcastCount = discardedBroadcastCount
        self.mail = mail
        self.meetings = meetings
        self.pending = pending
        self.omittedMailCount = omittedMailCount
        self.discardedMailCount = discardedMailCount
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

        let respondidas = answeredKeys(in: scopedMessages)

        var ranked: [Ranked] = []
        var fallback: [Ranked] = []
        ranked.reserveCapacity(mailLimit)
        fallback.reserveCapacity(mailLimit)
        var scanned = 0
        var descartadas = 0
        // Os ids varridos que o cabeçalho denuncia como disparo. Conjunto, e
        // não contador, porque o que interessa no fim é quantos **não**
        // apareceram — e isso só se sabe depois de a lista estar pronta.
        var disparos: Set<String> = []
        for message in scopedMessages {
            guard isRelevantCandidate(message, now: now) else { continue }
            guard scanned < candidateCap else { break }
            scanned += 1
            if message.effectiveBulkMarks.isBulk { disparos.insert(message.id) }
            if isAnswered(message, by: respondidas) {
                // Não conta como descartada por ruído: ela **foi** trabalho, e
                // o trabalho está feito. Somá-la ao "N fora da lista ·
                // newsletters e avisos" diria que ela era ruído.
                continue
            }
            if let hit = rank(message, now: now) {
                ranked.append(hit)
            } else {
                descartadas += 1
                if fallback.count < mailLimit, let hit = todayFallback(message, now: now) {
                    fallback.append(hit)
                }
            }
        }
        ranked.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.item.message.receivedAt > b.item.message.receivedAt
        }
        if ranked.isEmpty {
            ranked = fallback
            // O que virou lista de reserva deixa de ser excedente: ele está
            // na tela, e contá-lo dos dois lados faria a faixa somar errado.
            descartadas = max(0, descartadas - ranked.count)
        }
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
            pending: Array(scopedPending.filter { item in
                guard let date = item.dueDate else { return true }
                let today = Calendar.current.startOfDay(for: now)
                let end = Calendar.current.date(byAdding: .day, value: freshnessDays + 1, to: today)!
                return date >= today && date < end
            }.prefix(pendingLimit)),
            omittedMailCount: max(0, ranked.count - mailLimit),
            omittedMeetingCount: max(0, upcoming.count - meetingLimit),
            nextUpLabel: AgendaSummary.nextUpLabel(for: scopedAgenda.filter { $0.dayOffset == 0 }, now: nowMinute),
            discardedMailCount: descartadas,
            discardedBroadcastCount: disparos.subtracting(mail.map(\.id)).count
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
        case ..<720: hello = L10n.tr("Bom dia")
        case ..<1080: hello = L10n.tr("Boa tarde")
        default: hello = L10n.tr("Boa noite")
        }
        let first = name?
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init)
        if let first, !first.isEmpty, !first.contains("@") {
            return L10n.tr("\(hello), \(first)")
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

    // MARK: - O que já foi respondido

    /// A conversa e a mensagem que uma resposta **nossa** já resolveu.
    ///
    /// Duas chaves porque as duas fontes existem: o app grava `threadKey` no
    /// que sincroniza, e grava `References` no que ele mesmo manda. Uma conta
    /// que veio de fixture não tem nenhuma das duas, e aí nada é resolvido —
    /// que é o comportamento honesto: sem prova de resposta, a mensagem
    /// continua pedindo a pessoa.
    private struct Answered {
        /// `conversationKey` → o instante da resposta mais recente nela.
        var threads: [String: Date] = [:]
        /// Os `Message-ID` que alguma resposta nossa citou.
        var messageIDs: Set<String> = []
    }

    private static func answeredKeys(in messages: [Message]) -> Answered {
        var answered = Answered()
        for message in messages where message.bucket == .sent {
            let chave = message.conversationKey
            if let anterior = answered.threads[chave] {
                answered.threads[chave] = max(anterior, message.receivedAt)
            } else {
                answered.threads[chave] = message.receivedAt
            }
            answered.messageIDs.formUnion(message.references)
        }
        return answered
    }

    /// Já respondida: a resposta cita esta mensagem, ou saiu **depois** dela na
    /// mesma conversa.
    ///
    /// O "depois" não é detalhe: uma conversa antiga que já teve resposta e
    /// recebeu uma pergunta nova hoje continua sendo trabalho por fazer, e
    /// tratá-la como resolvida esconderia justamente o que chegou agora.
    private static func isAnswered(_ message: Message, by answered: Answered) -> Bool {
        if let id = message.rfcMessageID, answered.messageIDs.contains(id) { return true }
        guard let quando = answered.threads[message.conversationKey] else { return false }
        return quando >= message.receivedAt
    }

    /// `nil` é "isto não pede a pessoa agora". Promoções e redes só passam
    /// se já tiverem sido sinalizadas ou marcadas como resposta — o filtro
    /// não esconde um follow-up que a pessoa mesma marcou.
    private static func rank(_ message: Message, now: Date) -> Ranked? {
        guard isRelevantCandidate(message, now: now) else { return nil }

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
        // A barreira determinística, **depois** do modelo: o que o cabeçalho
        // afirma não é palpite, e o modelo não pode desfazê-lo. Um disparo em
        // massa não pede resposta — e, por isso, também não ocupa nenhuma das
        // faixas fortes (resposta, lead, prazo). Ver `BulkMailMarks`.
        let marcas = message.effectiveBulkMarks
        let triagem = message.triage?.barred(byBulk: marcas)
        let deadline = relevantDeadline(for: message, now: now)
        var sinais: Signals
        if isRecent(message, now: now), !hasClosedInvitation(message, now: now) {
            sinais = triagem.map { triageSignals($0, deadline: deadline, now: now) } ?? tagSignals(message)
        } else {
            sinais = Signals(score: deadline.map { deadlineWeight($0.date, now: now) } ?? 0,
                             reason: deadline == nil ? nil : .deadline,
                             needsReply: false, isBackgroundNoise: false)
        }
        if marcas.isBulk {
            sinais.score = deadline.map { deadlineWeight($0.date, now: now) } ?? 0
            sinais.reason = deadline == nil ? nil : .deadline
        }

        // Ruído de fundo é o que ninguém marcou: a newsletter e o recibo
        // saem, mas a estrela da pessoa e um "precisa resposta" os trazem de
        // volta — o filtro não pode esconder o que ela mesma sinalizou.
        if sinais.isBackgroundNoise {
            guard message.isFlagged || sinais.needsReply || deadline != nil else { return nil }
        }

        var score = sinais.score
        var reason: Reason? = sinais.reason
        if message.isFlagged {
            score += Weight.flagged
            reason = reason ?? .flagged
        }
        // A etiqueta de disparo vem **antes** de "não lido" e "hoje": entre
        // dizer que a linha ainda não foi aberta e dizer que ela é uma máquina
        // falando com uma lista, a segunda é a que decide o que fazer com ela.
        if marcas.isBulk {
            reason = reason ?? .broadcast
        }
        if !message.isRead {
            score += Weight.unread
            reason = reason ?? .unread
        }

        switch message.bucket {
        case .today:
            score += 20
        case .all:
            score += 10
        case .later, .archived, .junk, .trash, .drafts, .sent:
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
        if needsReply { signals.score += Weight.needsReply }
        if hasTag(message, "Lead") { signals.score += Weight.lead }
        if hasTag(message, "Prazo") { signals.score += Weight.deadlineNear }
        signals.reason = strongestReason(
            deadline: hasTag(message, "Prazo"), lead: hasTag(message, "Lead"),
            needsReply: needsReply
        )
        return signals
    }

    /// Qual dos três sinais fortes vira **etiqueta**.
    ///
    /// Separado da soma de propósito: a soma decide a **posição** na coluna, e
    /// a etiqueta diz **por quê**. Uma mensagem pode ser as três coisas ao
    /// mesmo tempo, e a linha só tem espaço para uma palavra.
    ///
    /// A ordem é da mais específica para a mais genérica — lead, prazo,
    /// resposta —, e não a da soma. "Precisa resposta" é verdade sobre quase
    /// tudo que chega e por isso informa pouco; "Prazo" traz uma data e "Lead"
    /// traz dinheiro, e são elas que dizem o que fazer primeiro. Foi
    /// justamente a etiqueta genérica repetida sete vezes que fez a coluna do
    /// dono custar atenção sem devolver nada.
    ///
    /// Lead vem antes de prazo porque é o mais raro dos três e o que muda de
    /// natureza: um prazo é uma data dentro de um trabalho que já existe, e um
    /// lead é trabalho que ainda não existe. A faixa HOJE conta leads por esta
    /// etiqueta (`DashboardToday`), e rebaixá-la faria a faixa parar de contar
    /// um lead com data marcada — que é o mais valioso dos dois.
    private static func strongestReason(
        deadline: Bool, lead: Bool, needsReply: Bool
    ) -> Reason? {
        if lead { return .lead }
        if deadline { return .deadline }
        if needsReply { return .needsReply }
        return nil
    }

    /// A escala, num lugar só.
    ///
    /// **Duas ordens de grandeza, de propósito.** Os três sinais fortes valem
    /// centenas; estrela, leitura, caixa e urgência valem dezenas. Isso é o que
    /// dá à coluna um topo óbvio em vez de sete linhas empatadas: nenhuma soma
    /// de sinais fracos alcança um sinal forte, então uma mensagem que pede
    /// resposta nunca fica atrás de uma que só chegou hoje e não foi aberta.
    ///
    /// Foi exatamente esse alcance que faltava: com resposta valendo 100 e os
    /// modificadores valendo 50 + 30 + 20, qualquer disparo sinalizado e não
    /// lido **empatava** com um cliente esperando — e o desempate caía na data,
    /// que é o mesmo que não ter prioridade nenhuma.
    private enum Weight {
        static let needsReply = 1_000
        static let lead = 800
        static let deadlineNear = 700
        static let deadlineSoon = 500
        static let deadlineFar = 300
        static let flagged = 50
        static let unread = 30
        static let highUrgency = 20
    }

    /// A mesma escala, agora com o que a análise afirmou. O prazo pesa pela
    /// distância: o que vence hoje vale mais do que o que vence na semana que
    /// vem, e sem isso "Prazo" seria um rótulo sem hierarquia nenhuma.
    private static func triageSignals(
        _ triage: MessageTriage, deadline: DetectedDeadline?, now: Date
    ) -> Signals {
        var signals = Signals(
            score: 0, reason: nil, needsReply: triage.needsReply,
            isBackgroundNoise: triage.intent.isBackgroundNoise
        )
        if triage.needsReply { signals.score += Weight.needsReply }
        if triage.intent == .lead { signals.score += Weight.lead }
        if let deadline {
            signals.score += deadlineWeight(deadline.date, now: now)
        }
        signals.reason = strongestReason(
            deadline: deadline != nil,
            lead: triage.intent == .lead,
            needsReply: triage.needsReply
        )
        // Urgência é peso, não motivo: ela desempata duas mensagens do mesmo
        // tipo sem inventar um sétimo caso de `Reason` para a tela escrever.
        if triage.urgency == .high {
            signals.score += Weight.highUrgency
        }
        return signals
    }

    /// 700 até 24 h, 500 até 72 h, 300 depois — a faixa forte, como resposta e
    /// lead. O chamador primeiro confere se a data e o contexto ainda são
    /// atuais; um aviso de meses atrás não recebe peso por estar vencido.
    static func deadlineWeight(_ deadline: Date, now: Date) -> Int {
        let horas = deadline.timeIntervalSince(now) / 3_600
        if horas <= 24 { return Weight.deadlineNear }
        if horas <= 72 { return Weight.deadlineSoon }
        return Weight.deadlineFar
    }

    private static func todayFallback(_ message: Message, now: Date) -> Ranked? {
        guard Calendar.current.isDate(message.receivedAt, inSameDayAs: now) else { return nil }
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
