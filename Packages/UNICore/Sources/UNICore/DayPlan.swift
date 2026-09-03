import Foundation

/// O dia como a IA o entendeu: uma frase para começar, três seções, uma
/// proposta por linha, o que foi tirado da lista e onde cabe responder tudo.
///
/// É o cérebro do dashboard 08, e é **puro**: entra o recorte que a Caixa já
/// faz (`DashboardFocus`), os rascunhos prontos, as regras que a pessoa
/// ensinou e a agenda; sai a tela inteira em dados. Nenhuma decisão vive numa
/// `View`, nenhuma consulta ao relógio acontece aqui dentro — `now` e
/// `nowMinute` entram pela porta, como no `DashboardFocus`.
///
/// **A IA nunca executa.** Tudo aqui é `Proposal`: a palavra é literal, e o
/// tipo não tem nenhum caso que "já fez". Quem executa é o clique, pela fila
/// transacional.
public struct DayPlan: Sendable, Hashable {

    /// A frase do topo — a única caixa de cor da tela.
    public struct Hero: Sendable, Hashable {
        public let messageID: String
        public let sentence: String
        public let hasReadyDraft: Bool

        public init(messageID: String, sentence: String, hasReadyDraft: Bool) {
            self.messageID = messageID
            self.sentence = sentence
            self.hasReadyDraft = hasReadyDraft
        }
    }

    /// O que a IA sugere para uma linha. Quatro casos e nada mais: um enum
    /// aberto viraria convite para a tela inventar botão sem regra.
    public enum Proposal: Sendable, Hashable {
        /// Rascunho pronto para **esta** versão da mensagem.
        case sendDraft(messageID: String, preview: String)
        /// Sem prazo e sem rascunho: cabe no próximo dia útil de manhã.
        case later(messageID: String, until: Date, why: String)
        /// Disparo de quem a pessoa nunca abriu.
        case archiveAndLearn(messageID: String, why: String)
        /// Nenhuma sugestão forte. A linha fica, sem botão primário.
        case keep(messageID: String, why: String)

        public var messageID: String {
            switch self {
            case let .sendDraft(id, _), let .later(id, _, _),
                 let .archiveAndLearn(id, _), let .keep(id, _):
                id
            }
        }

        /// A frase que a linha escreve depois do `↳`.
        public var text: String {
            switch self {
            case let .sendDraft(_, preview): "Resposta pronta. \(preview)"
            case let .later(_, _, why): why
            case let .archiveAndLearn(_, why): why
            case let .keep(_, why): why
            }
        }

        /// Só o rascunho pronto ganha o `↳` em acento. O resto é sugestão, e
        /// sugestão não se anuncia com a cor de "já está feito".
        public var isReadyDraft: Bool {
            if case .sendDraft = self { return true }
            return false
        }
    }

    public struct Row: Sendable, Hashable, Identifiable {
        public let id: String
        public let item: DashboardFocus.MailItem
        public let why: String
        public let proposal: Proposal

        public init(
            id: String, item: DashboardFocus.MailItem, why: String, proposal: Proposal
        ) {
            self.id = id
            self.item = item
            self.why = why
            self.proposal = proposal
        }
    }

    public struct Section: Sendable, Hashable {
        public enum Kind: String, Sendable, Hashable, CaseIterable {
            case waitingOnYou
            case due
            case lead

            /// O rótulo do 08: "Esperando você", "Vence", "Lead".
            public var label: String {
                switch self {
                case .waitingOnYou: "Esperando você"
                case .due: "Vence"
                case .lead: "Lead"
                }
            }

            /// A categoria do filtro a que esta seção responde.
            public var category: Filter.Category {
                switch self {
                case .waitingOnYou: .people
                case .due: .deadlines
                case .lead: .leads
                }
            }
        }

        public let kind: Kind
        public let rows: [Row]

        public init(kind: Kind, rows: [Row]) {
            self.kind = kind
            self.rows = rows
        }
    }

    /// O filtro em texto do 08. `accounts` vazio é "todas" — e não "nenhuma",
    /// que deixaria a tela em branco no primeiro desenho.
    public struct Filter: Sendable, Hashable {
        public enum Category: String, Sendable, Hashable, CaseIterable {
            case people
            case deadlines
            case leads
            case broadcasts
            case newsletters

            public var label: String {
                switch self {
                case .people: "Gente"
                case .deadlines: "Prazos"
                case .leads: "Leads"
                case .broadcasts: "Disparos"
                case .newsletters: "Newsletters"
                }
            }
        }

        public var on: Set<Category>
        public var accounts: Set<String>

        public init(on: Set<Category>, accounts: Set<String> = []) {
            self.on = on
            self.accounts = accounts
        }

        /// O que o 08 abre ligado: gente, prazos e leads.
        public static let standard = Filter(on: [.people, .deadlines, .leads])
    }

    /// Uma linha que não chegou à lista, e por quê. O rodapé "Tirei da lista
    /// hoje" existe para que a pessoa possa discordar — e para isso precisa do
    /// assunto, não só do id.
    public struct Removed: Sendable, Hashable {
        public let messageID: String
        public let subject: String
        public let why: String

        public init(messageID: String, subject: String, why: String) {
            self.messageID = messageID
            self.subject = subject
            self.why = why
        }
    }

    /// O bloco sugerido da coluna do dia.
    public struct ReplyBlock: Sendable, Hashable {
        public let day: Int
        public let startMinute: Int
        public let minutes: Int
        public let messageIDs: [String]

        public init(day: Int, startMinute: Int, minutes: Int, messageIDs: [String]) {
            self.day = day
            self.startMinute = startMinute
            self.minutes = minutes
            self.messageIDs = messageIDs
        }
    }

    public let hero: Hero?
    public let sections: [Section]
    public let counts: [Filter.Category: Int]
    public let removed: [Removed]
    public let replyBlock: ReplyBlock?

    public init(
        hero: Hero?,
        sections: [Section],
        counts: [Filter.Category: Int],
        removed: [Removed],
        replyBlock: ReplyBlock?
    ) {
        self.hero = hero
        self.sections = sections
        self.counts = counts
        self.removed = removed
        self.replyBlock = replyBlock
    }

    // MARK: - Constantes de redação

    /// O rascunho que cabe numa linha e decide sozinho: acima disto o herói
    /// não promete "é sim ou não", porque não é.
    public static let shortDraftLimit = 160
    /// Uma frase, e uma frase que cabe na linha de 13pt do 08.
    public static let whyLimit = 120
    /// A prévia do rascunho na linha, entre aspas.
    public static let previewLimit = 90
    /// O bloco de resposta do 08: 20 minutos. Não cresce com o número de
    /// rascunhos — três respostas já escritas se enviam em vinte minutos, e um
    /// bloco de uma hora seria a agenda mentindo sobre o trabalho que resta.
    public static let replyBlockMinutes = 20
    /// A manhã do "deixar para depois".
    public static let morningMinute = 9 * 60

    // MARK: - A decisão

    public static func make(
        focus: DashboardFocus,
        drafts: [String: ReadyDraft],
        rules: [SenderRule],
        agenda: [AgendaItem],
        filter: Filter,
        now: Date,
        nowMinute: Int
    ) -> DayPlan {
        let caladas = SenderRule.silencedAddresses(rules)

        var porSecao: [Section.Kind: [Row]] = [:]
        var contagem: [Filter.Category: Int] = [:]
        var tiradas: [(row: Removed, accountID: String)] = []

        for item in focus.mail {
            let mensagem = item.message
            let marcas = mensagem.effectiveBulkMarks
            let triagem = mensagem.triage?.barred(byBulk: marcas)
            let classe = classify(message: mensagem, marks: marcas, triage: triagem)

            // A contagem é do que **chegou**, não do que sobrou: a tela escreve
            // "Disparos 13" mesmo com os treze fora da lista, e é isso que
            // permite religá-los sabendo quantos são.
            contagem[classe.category, default: 0] += 1

            if caladas.contains(SenderRule.normalize(mensagem.from.address)) {
                tiradas.append(
                    (
                        Removed(
                            messageID: mensagem.id,
                            subject: mensagem.subject,
                            why: SenderRule.removalReason
                        ),
                        mensagem.accountID
                    )
                )
                continue
            }

            guard let secao = classe.section else {
                if let motivo = classe.removalReason {
                    tiradas.append(
                        (
                            Removed(
                                messageID: mensagem.id, subject: mensagem.subject, why: motivo
                            ),
                            mensagem.accountID
                        )
                    )
                }
                continue
            }

            let rascunho = drafts[mensagem.id].flatMap { $0.matches(mensagem) ? $0 : nil }
            let linha = Row(
                id: mensagem.id,
                item: item,
                why: why(for: mensagem, triage: triagem),
                proposal: proposal(
                    message: mensagem,
                    triage: triagem,
                    marks: marcas,
                    draft: rascunho,
                    peers: focus.mail,
                    now: now
                )
            )
            porSecao[secao, default: []].append(linha)
        }

        // O que a triagem descartou antes mesmo de ranquear — newsletter,
        // recibo, aviso — não tem linha para contar, mas tem número.
        if focus.discardedMailCount > 0 {
            contagem[.newsletters, default: 0] += focus.discardedMailCount
        }
        // E os disparos que nem couberam nas sete linhas. Sem isto o filtro
        // escreveria "Disparos 6" numa caixa com treze, e religá-lo mostraria
        // sete linhas que o número não tinha prometido.
        if focus.discardedBroadcastCount > 0 {
            contagem[.broadcasts, default: 0] += focus.discardedBroadcastCount
        }

        let contas = filter.accounts
        func passa(_ linha: Row) -> Bool {
            contas.isEmpty || contas.contains(linha.item.message.accountID)
        }

        var secoes: [Section] = []
        for tipo in Section.Kind.allCases {
            guard filter.on.contains(tipo.category) else { continue }
            let linhas = (porSecao[tipo] ?? []).filter(passa)
            guard !linhas.isEmpty else { continue }
            secoes.append(Section(kind: tipo, rows: linhas))
        }

        let esperando = secoes.first { $0.kind == .waitingOnYou }?.rows ?? []
        let heroi = hero(from: esperando, drafts: drafts, now: now)

        let visiveis = secoes.flatMap(\.rows)
        let bloco = replyBlock(
            rows: visiveis, agenda: agenda, now: now, nowMinute: nowMinute
        )

        return DayPlan(
            hero: heroi,
            sections: secoes,
            counts: contagem,
            removed: tiradas
                .filter { contas.isEmpty || contas.contains($0.accountID) }
                .map(\.row),
            replyBlock: bloco
        )
    }

    // MARK: - Classificação

    /// Onde a linha entra e o que ela conta.
    private struct Classification {
        let section: Section.Kind?
        let category: Filter.Category
        let removalReason: String?
    }

    /// A ordem é a do `DashboardFocus.strongestReason`, com uma exceção que o
    /// 08 exige: **o disparo vem antes de tudo**, porque o cabeçalho não é
    /// palpite. O que o remetente assinou vence o que o modelo achou — foi
    /// exatamente por deixar o modelo vencer que o marketing da Zoho chegou ao
    /// topo com a etiqueta de lead.
    ///
    /// A única coisa que sobrevive ao disparo é o **prazo**: `barred(byBulk:)`
    /// nega "precisa resposta" e mais nada, e uma data que o texto cita
    /// continua sendo uma data. Os créditos da Abacus expiram sábado tenha ou
    /// não a mensagem vindo de uma lista — por isso ela fica em "Vence", com a
    /// proposta de arquivar e aprender ao lado.
    private static func classify(
        message: Message, marks: BulkMailMarks, triage: MessageTriage?
    ) -> Classification {
        if marks.isBulk {
            if triage?.deadline != nil {
                return Classification(
                    section: .due, category: .deadlines, removalReason: nil
                )
            }
            // "Campanha, não lead" é a discordância explícita: a análise disse
            // lead e o cabeçalho desmentiu. Vale a pena escrever assim porque é
            // a única removida sobre a qual a pessoa pode ter opinião.
            let motivo = triage?.intent == .lead ? "campanha, não lead" : "disparo"
            return Classification(
                section: nil, category: .broadcasts, removalReason: motivo
            )
        }
        if triage?.intent == .lead {
            return Classification(section: .lead, category: .leads, removalReason: nil)
        }
        if triage?.needsReply == true || (triage == nil && message.hasNeedsReplyTag) {
            return Classification(
                section: .waitingOnYou, category: .people, removalReason: nil
            )
        }
        if triage?.deadline != nil {
            return Classification(section: .due, category: .deadlines, removalReason: nil)
        }
        if triage?.intent.isBackgroundNoise == true {
            return Classification(
                section: nil, category: .newsletters, removalReason: nil
            )
        }
        // Sem triagem e sem sinal: a linha ficou no recorte por estrela ou por
        // ser de hoje. Ela é "gente" — e continua na lista, com `keep`.
        return Classification(section: .waitingOnYou, category: .people, removalReason: nil)
    }

    // MARK: - O herói

    private static func hero(
        from rows: [Row], drafts: [String: ReadyDraft], now: Date
    ) -> Hero? {
        guard !rows.isEmpty else { return nil }
        let ordenadas = rows.sorted { $0.item.message.receivedAt < $1.item.message.receivedAt }
        let comRascunho = ordenadas.first { $0.proposal.isReadyDraft }
        guard let escolhida = comRascunho ?? ordenadas.first else { return nil }

        let mensagem = escolhida.item.message
        let nome = DashboardFocus.personName(
            displayName: mensagem.from.name, address: mensagem.from.address
        ) ?? mensagem.from.name
        let espera = waitLabel(since: mensagem.receivedAt, now: now)

        guard comRascunho != nil else {
            return Hero(
                messageID: mensagem.id,
                sentence: "\(nome) \(espera).",
                hasReadyDraft: false
            )
        }
        let rascunho = drafts[mensagem.id]
        let curto = (rascunho?.text.count ?? .max) <= shortDraftLimit
        let frase = curto
            ? "\(nome) \(espera), e é sim ou não. A resposta já está escrita."
            : "\(nome) \(espera). A resposta já está escrita."
        return Hero(messageID: mensagem.id, sentence: frase, hasReadyDraft: true)
    }

    /// "espera há 7 dias" — e "espera desde hoje" quando ainda não virou um
    /// dia. Contar "há 0 dias" seria dizer que a pessoa está atrasada com algo
    /// que chegou às nove da manhã.
    ///
    /// **Dias de calendário, não períodos de 24 h.** O email do Jack é de 27 de
    /// agosto e hoje é 3 de setembro: são sete dias, e é o que qualquer pessoa
    /// diria. Contar em horas daria seis — porque ele chegou às 14h12 e agora
    /// são 10h —, e a frase do herói passaria a depender da hora do dia.
    static func waitLabel(since: Date, now: Date, calendar: Calendar = .current) -> String {
        let dias = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: since),
            to: calendar.startOfDay(for: now)
        ).day ?? 0
        switch dias {
        case ..<1: return "espera desde hoje"
        case 1: return "espera há 1 dia"
        default: return "espera há \(dias) dias"
        }
    }

    // MARK: - O porquê

    /// Por que esta linha está aqui, em uma frase.
    ///
    /// A ordem é da prova mais forte para a mais fraca. **A pergunta literal
    /// vem primeiro** porque é a única que não é interpretação: são as palavras
    /// do remetente, entre aspas, e a pessoa pode conferi-las com os olhos. O
    /// resumo é o modelo falando; o prazo é o que sobra quando ninguém
    /// perguntou nada.
    static func why(for message: Message, triage: MessageTriage?) -> String {
        if triage?.needsReply == true, let pergunta = literalQuestion(in: message) {
            return clamp(quoted(pergunta), to: whyLimit)
        }
        if let resumo = message.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !resumo.isEmpty {
            return clamp(sentenceEnded(resumo), to: whyLimit)
        }
        if let prazo = triage?.deadline?.evidence.trimmingCharacters(in: .whitespacesAndNewlines),
           !prazo.isEmpty {
            return clamp(sentenceEnded(prazo), to: whyLimit)
        }
        return clamp(sentenceEnded(message.subject), to: whyLimit)
    }

    /// A primeira frase terminada em "?" no resumo curto ou no corpo.
    ///
    /// O `MessageTriage` não guarda a pergunta — ele guarda o juízo ("precisa
    /// resposta") e a única citação que a spec exige, a do prazo. Enquanto não
    /// houver campo, a pergunta se extrai do texto que já está na mão, e o
    /// juízo do modelo é o que autoriza procurá-la: sem `needsReply`, um "?"
    /// solto numa newsletter viraria "o que ele perguntou".
    static func literalQuestion(in message: Message) -> String? {
        for texto in [message.snippet] + message.body {
            if let pergunta = firstQuestion(in: texto) { return pergunta }
        }
        return nil
    }

    private static func firstQuestion(in text: String) -> String? {
        guard let fim = text.firstIndex(of: "?") else { return nil }
        let ate = text[text.startIndex...fim]
        // A frase começa depois do último ponto final, "!" ou quebra de linha
        // antes do "?".
        let corte = ate.lastIndex { $0 == "." || $0 == "!" || $0 == "\n" }
        let inicio = corte.map { ate.index(after: $0) } ?? ate.startIndex
        let frase = ate[inicio...].trimmingCharacters(in: .whitespacesAndNewlines)
        return frase.count > 1 ? frase : nil
    }

    // MARK: - A proposta

    private static func proposal(
        message: Message,
        triage: MessageTriage?,
        marks: BulkMailMarks,
        draft: ReadyDraft?,
        peers: [DashboardFocus.MailItem],
        now: Date
    ) -> Proposal {
        if let draft {
            return .sendDraft(
                messageID: message.id,
                preview: clamp(quoted(draft.firstSentence), to: previewLimit)
            )
        }
        if triage?.deadline == nil, triage?.needsReply == true {
            let quando = nextBusinessMorning(after: now)
            return .later(
                messageID: message.id,
                until: quando.date,
                why: "Sem prazo, e exige \(actionLabel(triage?.intent)). "
                    + "Deixar para \(quando.name) de manhã?"
            )
        }
        if marks.isBulk, neverOpened(message.from.address, in: peers) {
            return .archiveAndLearn(
                messageID: message.id,
                why: "Você nunca abriu um email deles — arquivar e não trazer mais?"
            )
        }
        return .keep(messageID: message.id, why: "Sem sugestão forte — deixo como está.")
    }

    /// O que a linha exige de você, para caber em "Sem prazo, e exige …".
    private static func actionLabel(_ intent: MessageTriage.Intent?) -> String {
        switch intent {
        case .scheduling: "olhar a agenda"
        case .lead: "uma proposta"
        case .request: "a sua atenção"
        default: "uma resposta"
        }
    }

    /// A pessoa nunca abriu nada deste remetente.
    ///
    /// Sobre o recorte que está na mão — é o que existe de graça, e é honesto:
    /// a proposta é uma **pergunta** ("arquivar e não trazer mais?"), não uma
    /// conclusão. Sem nenhuma mensagem do remetente, ninguém "nunca abriu"
    /// coisa nenhuma, e a proposta não aparece.
    private static func neverOpened(
        _ address: String, in peers: [DashboardFocus.MailItem]
    ) -> Bool {
        let alvo = SenderRule.normalize(address)
        let dele = peers.filter { SenderRule.normalize($0.message.from.address) == alvo }
        guard !dele.isEmpty else { return false }
        return dele.allSatisfy { !$0.message.isRead }
    }

    /// O próximo dia útil às 9h, e o nome dele. Sexta cai na segunda.
    static func nextBusinessMorning(
        after now: Date, calendar: Calendar = .current
    ) -> (date: Date, name: String) {
        var dia = now
        for _ in 1...7 {
            guard let proximo = calendar.date(byAdding: .day, value: 1, to: dia) else { break }
            dia = proximo
            let semana = calendar.component(.weekday, from: dia)
            if semana == 1 || semana == 7 { continue }
            let manha = calendar.date(
                bySettingHour: morningMinute / 60, minute: 0, second: 0, of: dia
            ) ?? dia
            return (manha, weekdayName(semana))
        }
        return (now, weekdayName(calendar.component(.weekday, from: now)))
    }

    /// Os nomes em pt-BR, sem depender do `Locale` da máquina: a tela é em
    /// português mesmo num Mac em alemão, e foi assim que a agenda já escreveu
    /// "Donnerstag" numa tela em português.
    static func weekdayName(_ weekday: Int) -> String {
        switch weekday {
        case 1: "domingo"
        case 2: "segunda"
        case 3: "terça"
        case 4: "quarta"
        case 5: "quinta"
        case 6: "sexta"
        default: "sábado"
        }
    }

    // MARK: - O bloco de resposta

    /// A primeira folga de hoje que cabe **antes** do prazo mais próximo.
    ///
    /// Reservar as respostas para depois do prazo do Jayden seria a agenda
    /// ajudando a perder o prazo. Sem folga nenhuma, `nil` — a coluna do dia
    /// simplesmente não escreve bloco, em vez de inventar um horário ocupado.
    private static func replyBlock(
        rows: [Row], agenda: [AgendaItem], now: Date, nowMinute: Int,
        calendar: Calendar = .current
    ) -> ReplyBlock? {
        let ids = rows.filter { $0.proposal.isReadyDraft }.map(\.id)
        guard !ids.isEmpty else { return nil }

        let limite = nearestDeadlineMinute(rows: rows, now: now, calendar: calendar)
        let folgas = FreeSlots.next(
            days: 1, minMinutes: replyBlockMinutes, agenda: agenda,
            workday: FreeSlots.workday, now: now, nowMinute: nowMinute,
            calendar: calendar
        )
        for folga in folgas {
            let fim = folga.start + replyBlockMinutes
            if let limite, fim > limite { continue }
            return ReplyBlock(
                day: folga.day, startMinute: folga.start,
                minutes: replyBlockMinutes, messageIDs: ids
            )
        }
        return nil
    }

    /// O prazo de **hoje** mais próximo, em minutos desde a meia-noite. Prazo
    /// de outro dia não aperta o bloco de hoje.
    private static func nearestDeadlineMinute(
        rows: [Row], now: Date, calendar: Calendar
    ) -> Int? {
        let hoje = rows
            .compactMap { $0.item.message.triage?.deadline?.date }
            .filter { calendar.isDate($0, inSameDayAs: now) }
            .map { data -> Int in
                let partes = calendar.dateComponents([.hour, .minute], from: data)
                return (partes.hour ?? 0) * 60 + (partes.minute ?? 0)
            }
        return hoje.min()
    }

    // MARK: - Texto

    /// Entre aspas curvas, como o desenho escreve.
    static func quoted(_ text: String) -> String {
        "\u{201C}\(text)\u{201D}"
    }

    /// A primeira frase de um texto corrido.
    static func firstSentence(of text: String) -> String {
        let limpo = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let fim = limpo.firstIndex(where: { $0 == "." || $0 == "?" || $0 == "!" })
        else { return limpo }
        return String(limpo[limpo.startIndex...fim])
    }

    /// Termina em ponto quando o texto não termina em pontuação nenhuma.
    static func sentenceEnded(_ text: String) -> String {
        let limpo = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ultimo = limpo.last else { return limpo }
        return ".?!…".contains(ultimo) ? limpo : limpo + "."
    }

    /// Corta no limite com reticências — inclusive quando o texto está entre
    /// aspas, e aí a aspa de fechar sobrevive ao corte.
    static func clamp(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let fecha = text.hasSuffix("\u{201D}")
        let miolo = String(text.prefix(limit - (fecha ? 2 : 1)))
            .trimmingCharacters(in: .whitespaces)
        return fecha ? miolo + "…\u{201D}" : miolo + "…"
    }
}

extension Message {
    /// O que "precisa resposta" quer dizer para quem ainda não foi triado: a
    /// etiqueta, que é o que as contas de exemplo têm.
    var hasNeedsReplyTag: Bool {
        tags.contains { $0.name == "Precisa resposta" }
    }
}
