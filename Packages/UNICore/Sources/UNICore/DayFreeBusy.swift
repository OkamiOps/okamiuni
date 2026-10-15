import Foundation

/// A trilha de 8h às 19h que a folha de novo compromisso mostra do dia
/// escolhido — e o veredito em uma frase.
///
/// Protótipo (`ModalAgenda.dc.html`): `const S = 8, SPAN = 11`, cada faixa
/// posicionada em porcentagem por `pct(x) = ((x - S) / SPAN) * 100`, a faixa
/// nova tracejada, e acima dela a linha "15h está livre · a Call Marina vem
/// logo depois, às 16h".
///
/// Pura, e fora de `View`, por duas razões: o veredito é a parte que pode
/// estar errada (um compromisso que começa às 15:59 **não** é colisão, e um
/// que termina às 15:00 também não), e porque assim ele se testa sem desenhar.
public struct DayFreeBusy: Sendable, Equatable {

    /// Uma faixa já medida em fração da trilha, pronta para o desenho.
    public struct Band: Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        /// 0…1 a partir da borda esquerda da trilha.
        public let start: Double
        /// 0…1. Já cortada nas pontas quando o compromisso sai da janela.
        public let width: Double
        /// O compromisso é do dia todo, uma refeição, uma folga — algo que não
        /// disputa a hora com uma reunião.
        public let isSoft: Bool
        public let accountID: String

        public init(
            id: String, title: String, start: Double, width: Double,
            isSoft: Bool, accountID: String
        ) {
            self.id = id
            self.title = title
            self.start = start
            self.width = width
            self.isSoft = isSoft
            self.accountID = accountID
        }
    }

    /// O começo e o fim da janela visível, em minutos desde a meia-noite.
    /// 08:00 → 19:00, literal do protótipo.
    public static let windowStart = 8 * 60
    public static let windowEnd = 19 * 60
    public static var windowSpan: Int { windowEnd - windowStart }

    /// As marcas de hora do rodapé da trilha: 08 … 19, doze delas.
    public static let hourLabels: [String] = (8...19).map {
        $0 < 10 ? "0\($0)" : "\($0)"
    }

    public let bands: [Band]
    /// A faixa tracejada do compromisso que está sendo criado. `nil` quando ele
    /// cai inteiro fora de 8h–19h — a trilha então só mostra o dia.
    public let proposal: Band?
    /// O que colide com a proposta, se algo colidir.
    public let clash: Band?

    public var isFree: Bool { clash == nil }

    /// O compromisso que vem logo depois da proposta, para a segunda metade da
    /// frase ("a Call Marina vem logo depois, às 16h").
    public let next: Band?
    public let nextStartMinute: Int?

    public init(
        bands: [Band], proposal: Band?, clash: Band?, next: Band?, nextStartMinute: Int?
    ) {
        self.bands = bands
        self.proposal = proposal
        self.clash = clash
        self.next = next
        self.nextStartMinute = nextStartMinute
    }

    /// Monta a trilha a partir dos compromissos **reais** do dia.
    ///
    /// `items` é a agenda inteira; o filtro por dia acontece aqui para quem
    /// chama não ter de repetir a regra do `dayOffset`.
    public static func build(
        items: [AgendaItem],
        dayOffset: Int,
        proposalStart: Int?,
        proposalEnd: Int?,
        proposalLabel: String
    ) -> DayFreeBusy {
        let doDia = items
            .filter { $0.dayOffset == dayOffset && $0.endMinute > $0.startMinute }
            .sorted { $0.startMinute < $1.startMinute }

        let bands = doDia.compactMap { item in
            band(
                id: item.id, title: item.title,
                from: item.startMinute, to: item.endMinute,
                isSoft: isSoft(item.title), accountID: item.accountID
            )
        }

        guard let start = proposalStart, let end = proposalEnd, end > start else {
            return DayFreeBusy(bands: bands, proposal: nil, clash: nil, next: nil, nextStartMinute: nil)
        }

        let proposal = band(
            id: "uni.proposta", title: proposalLabel, from: start, to: end,
            isSoft: false, accountID: ""
        )

        // Colisão é sobreposição **aberta**: terminar às 15:00 e começar às
        // 15:00 não é colidir, e marcar isso como conflito faria a folha
        // reclamar da agenda bem montada.
        let colisao = doDia.first { item in
            !isSoft(item.title) && item.startMinute < end && item.endMinute > start
        }
        let seguinte = doDia.first { $0.startMinute >= end && !isSoft($0.title) }

        return DayFreeBusy(
            bands: bands,
            proposal: proposal,
            // Compromisso inteiro fora da janela visível ainda colide: o
            // veredito não depende de a faixa caber no desenho, e é por isso
            // que aqui ele cai no `Band` de largura zero em vez de desaparecer.
            clash: colisao.map(Self.verdictBand),
            next: seguinte.map(Self.verdictBand),
            nextStartMinute: seguinte?.startMinute
        )
    }

    /// O compromisso citado pela frase do veredito. Não é medida de desenho —
    /// é só nome e identidade, e por isso a largura é zero.
    static func verdictBand(_ item: AgendaItem) -> Band {
        band(
            id: item.id, title: item.title, from: item.startMinute, to: item.endMinute,
            isSoft: false, accountID: item.accountID
        ) ?? Band(
            id: item.id, title: item.title, start: 0, width: 0,
            isSoft: false, accountID: item.accountID
        )
    }

    /// Mede uma faixa, cortando o que passa das bordas. `nil` quando o
    /// compromisso não encosta na janela de 8h–19h.
    static func band(
        id: String, title: String, from: Int, to: Int, isSoft: Bool, accountID: String
    ) -> Band? {
        let clampedStart = max(from, windowStart)
        let clampedEnd = min(to, windowEnd)
        guard clampedEnd > clampedStart else { return nil }
        let span = Double(windowSpan)
        return Band(
            id: id, title: title,
            start: Double(clampedStart - windowStart) / span,
            width: Double(clampedEnd - clampedStart) / span,
            isSoft: isSoft, accountID: accountID
        )
    }

    /// O que não disputa a hora: almoço, café, bloco de foco, dia inteiro.
    /// Lista pequena e explícita — adivinhar por duração marcaria uma reunião
    /// de duas horas como "folga".
    static func isSoft(_ title: String) -> Bool {
        let lower = title.lowercased()
        let words = ["almoço", "almoco", "lunch", "café", "cafe", "folga", "pausa", "break"]
        return words.contains { lower.contains($0) }
    }

    /// "15h" — como a frase do veredito escreve uma hora cheia, e "15:30"
    /// quando não é cheia.
    public static func clockLabel(_ minute: Int) -> String {
        let hour = minute / 60
        let minutes = minute % 60
        return minutes == 0 ? "\(hour)h" : String(format: "%d:%02d", hour, minutes)
    }
}
