import AppKit
import SwiftUI
import UNICore
import UNIDesign

/// As medidas da direção **Mesa** — `design/Mesa2.dc.html` (estados `vazio`,
/// `nota`, `trabalhando` e `gaveta`) com os objetos `rascunho` e `evento` de
/// `design/Leitor-IA.dc.html`, lidas valor por valor dos estilos em linha.
///
/// Mora fora de qualquer `View` pelo motivo de sempre: uma `View` é
/// `@MainActor` implícito e um `static` lá dentro estoura quando um teste
/// `nonisolated` o lê.
enum MesaMetrics {

    /// A janela do desenho: `width: 880px; height: 744px`.
    static let windowSize = CGSize(width: 880, height: 744)

    // MARK: A barra da janela
    //
    // O desenho pinta as três bolinhas e lhes dá `padding: 20px 20px 12px`.
    // Aqui a janela é de verdade e os semáforos são os do sistema: quem manda
    // é a regra da casa (`TrafficLightLayout`), que foi o conserto de duas
    // rejeições. A altura é `windowBarHeight` e o conteúdo começa em
    // `windowContentInset`.

    static let headerTrailing: CGFloat = 20
    static let headerGap: CGFloat = 8
    /// `font-size: 13.5px; font-weight: 600` do "Assistente".
    static let titleSize: CGFloat = 13.5
    /// `font-size: 12px` da rota, e o ponto de 7 ao lado dela.
    static let routeSize: CGFloat = 12
    static let routeDot: CGFloat = 7
    static let swapSize: CGFloat = 12
    /// O ✦ do cabeçalho da gaveta: `width: 16px`.
    static let drawerGlyph: CGFloat = 16
    static let drawerTitleSize: CGFloat = 14
    static let drawerHintSize: CGFloat = 11
    static let drawerActionGlyph: CGFloat = 14
    /// `padding: 16px 18px 10px` do cabeçalho da gaveta.
    static let drawerHeaderPadding = EdgeInsets(top: 16, leading: 18, bottom: 10, trailing: 18)

    // MARK: A saudação do estado vazio — `padding: 10px 28px 0; gap: 4px`

    static let greetingPadding = EdgeInsets(top: 10, leading: 28, bottom: 0, trailing: 28)
    static let greetingGap: CGFloat = 4
    /// `font-size: 22px; font-weight: 700; letter-spacing: -0.02em`.
    static let greetingSize: CGFloat = 22
    static let greetingTracking: CGFloat = -0.02
    static let greetingSubSize: CGFloat = 13.5

    // MARK: A mesa — `margin: 12px 16px 0`, pontos a cada 22px

    static let mesaMargin = EdgeInsets(top: 12, leading: 16, bottom: 0, trailing: 16)
    static let dotSpacing: CGFloat = 22
    static let dotRadius: CGFloat = 1
    /// `padding` de dentro da mesa, onde os objetos assentam.
    static let mesaInset: CGFloat = 18
    /// A folga entre dois objetos empilhados na mesa.
    static let objectGap: CGFloat = 10
    /// A largura do objeto maior do desenho (`width: 560px` da NOTA). Na
    /// janela de 880 os objetos param aí e se centram; na gaveta de 400 eles
    /// tomam o que há.
    static let objectMaxWidth: CGFloat = 560

    // MARK: As sugestões do vazio — `padding: 12px 28px 4px`

    static let suggestionPadding = EdgeInsets(top: 12, leading: 28, bottom: 4, trailing: 28)
    /// `padding: 7px 4px; gap: 10px; font-size: 13px` — sem o recuo da
    /// esquerda, para a seta nascer na **mesma** coluna da borda do objeto.
    static let suggestionRowPadding = EdgeInsets(top: 7, leading: 0, bottom: 7, trailing: 4)
    static let suggestionGap: CGFloat = 10
    static let suggestionSize: CGFloat = 13
    static let suggestionGlyph: CGFloat = 13

    // MARK: A pergunta, que também é objeto — `padding: 8px 28px 0`

    static let askedPadding = EdgeInsets(top: 8, leading: 28, bottom: 0, trailing: 28)
    /// `max-width: 440px; padding: 10px 14px; font-size: 13.5px; line-height: 1.5`.
    static let askedMaxWidth: CGFloat = 440
    static let askedPaddingInner = EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
    static let askedSize: CGFloat = 13.5
    static let askedLineHeight: CGFloat = 1.5

    // MARK: Os passos — `padding: 12px 28px 0; gap: 7px; font-size: 11.5px`

    static let stepsPadding = EdgeInsets(top: 12, leading: 28, bottom: 0, trailing: 28)
    static let stepGap: CGFloat = 7
    static let stepSize: CGFloat = 11.5
    static let stepGlyph: CGFloat = 11
    /// `width: 8px; height: 8px` do ponto que pulsa.
    static let stepDot: CGFloat = 8

    // MARK: Um objeto da mesa
    //
    // O cartão do desenho: cabeçalho com versalete, corpo e a fileira de
    // ações. As três medidas vêm da gaveta de `Mesa2` e do rascunho de
    // `Leitor-IA`, que concordam.

    /// `padding: 12px 18px` do cabeçalho do objeto na janela; `10px 14px` na
    /// gaveta. O desenho usa o maior onde há largura.
    static let objectHeaderPadding = EdgeInsets(top: 11, leading: 16, bottom: 11, trailing: 16)
    /// `font-size: 10px; font-weight: 600; letter-spacing: 0.1em`.
    static let capsSize: CGFloat = 10
    static let capsTracking: CGFloat = 0.1
    static let capsGlyph: CGFloat = 11
    /// `width: 7px; height: 7px` do ponto colorido do versalete.
    static let capsDot: CGFloat = 7
    /// `padding: 12px 16px; gap: 8px` do corpo.
    static let objectBodyPadding = EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
    static let objectBodyGap: CGFloat = 8
    /// `font-size: 13.5px; line-height: 1.6` da prosa de um objeto.
    static let objectProseSize: CGFloat = 13.5
    static let objectProseLineHeight: CGFloat = 1.6
    /// `font-size: 14px; font-weight: 600` do título de um evento.
    static let objectTitleSize: CGFloat = 14
    static let objectSubSize: CGFloat = 12.5
    /// A linha de procedência, em mono: `font-size: 11px`.
    static let objectNoteSize: CGFloat = 11
    /// `padding: 11px 16px 14px; gap: 8px` da fileira de ações.
    static let objectActionPadding = EdgeInsets(top: 11, leading: 16, bottom: 14, trailing: 16)
    static let objectActionGap: CGFloat = 8

    // MARK: Os botões do desenho

    /// `padding: 8px 13px; font-size: 12.5px; font-weight: 600`.
    static let primaryPadding = EdgeInsets(top: 8, leading: 13, bottom: 8, trailing: 13)
    static let primarySize: CGFloat = 12.5
    /// `padding: 7px 12px; font-weight: 500` no secundário com moldura.
    static let secondaryPadding = EdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12)
    /// O "Parar aqui" do estado trabalhando: `padding: 8px 15px`.
    static let stopPadding = EdgeInsets(top: 8, leading: 15, bottom: 8, trailing: 15)

    // MARK: As perguntas seguintes — `gap: 8px; padding: 8px 13px`

    static let followUpGap: CGFloat = 8
    static let followUpSize: CGFloat = 12.5
    static let followUpPadding = EdgeInsets(top: 8, leading: 13, bottom: 8, trailing: 13)

    // MARK: O campo — `margin: 12px 16px 16px; padding: 10px 10px 10px 14px`

    static let fieldMargin = EdgeInsets(top: 12, leading: 16, bottom: 16, trailing: 16)
    static let fieldPadding = EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 10)
    static let fieldGap: CGFloat = 8
    static let fieldTextSize: CGFloat = 13.5
    static let fieldHintSize: CGFloat = 11
    /// `width: 30px; height: 30px` do botão ↑.
    static let sendSide: CGFloat = 30
    static let sendGlyph: CGFloat = 14
    /// A gaveta é mais estreita e o desenho a aperta: `margin: 10px 14px 14px;
    /// padding: 9px 9px 9px 13px`, botão de 28.
    static let drawerFieldMargin = EdgeInsets(top: 10, leading: 14, bottom: 14, trailing: 14)
    static let drawerFieldPadding = EdgeInsets(top: 9, leading: 13, bottom: 9, trailing: 9)
    static let drawerSendSide: CGFloat = 28

    // MARK: Animações

    /// `dotPulse 1.4s ease-in-out infinite` — ida e volta, logo 0,7s por meia.
    static let dotPulse = Animation.easeInOut(duration: 0.7).repeatForever(autoreverses: true)
    /// `skelSweep 1.5s linear infinite`.
    static let skeletonSweep = Animation.linear(duration: 1.5).repeatForever(autoreverses: false)
}

// MARK: - As palavras da Mesa

/// Os versaletes e rótulos da Mesa. Fora de uma `View` para terem teste.
public enum MesaCopy {

    /// O convite do estado vazio. **Não é o texto do desenho**: lá a frase é
    /// "separei o que não pode esperar", e ela só é verdade quando a triagem
    /// de fato rodou. Numa mesa vazia ela seria a tela mentindo sobre o
    /// trabalho — a mesma regra do recibo de passos.
    public static var emptyInvitation: String {
        L10n.tr("Pergunte, ou mande fazer. O que eu fizer aparece aqui na mesa.")
    }

    /// A segunda linha quando a mesa **tem** o que mostrar. Só então ela pode
    /// dizer que separou alguma coisa.
    public static var separated: String {
        L10n.tr("Separei o que não pode esperar.")
    }

    public static var note: String { L10n.tr("NOTA") }
    public static var draft: String { L10n.tr("RASCUNHO") }
    public static var draftWriting: String { L10n.tr("RASCUNHO · ESCREVENDO") }
    public static var event: String { L10n.tr("EVENTO · PROPOSTO") }
    public static var proposal: String { L10n.tr("PROPOSTA") }

    public static var openInComposer: String { L10n.tr("Abrir no compositor") }
    public static var addToAgenda: String { L10n.tr("Adicionar à agenda") }
    public static var copy: String { L10n.tr("Copiar") }
    public static var stopHere: String { L10n.tr("Parar aqui") }
}

// MARK: - O dia, em cima da mesa

/// **Um objeto do dia na mesa vazia** — `Mesa-vazio-escuro`: o e-mail que
/// espera há mais tempo, o próximo compromisso e uma promessa em aberto.
///
/// Os três saem do **mesmo** `DayPlan` que alimenta o Painel do Dia, da mesma
/// agenda e das mesmas promessas. Nada aqui é inventado: sem dado, o item não
/// existe, e a mesa diz outra coisa.
///
/// É um valor, e não um `switch` dentro da `View`, porque "o que entra na
/// mesa, e em que ordem" é decisão de produto — e porque a janela destacada
/// não alcança o `MailStore` e precisa receber isto pronto.
struct MesaDayItem: Identifiable, Hashable, Sendable {

    enum Kind: String, Sendable { case email, meeting, promise }

    let id: String
    let kind: Kind
    /// O versalete: "E-MAIL · ESPERANDO HÁ 2 DIAS".
    let caps: String
    let title: String
    let detail: String
    /// O rótulo do botão — o verbo do desenho.
    let verb: String
    /// A pergunta que o botão manda ao assistente. É o único efeito dele:
    /// a mesa vazia **propõe**, e quem executa continua sendo o cartão que
    /// voltar da resposta.
    let ask: String
    /// A mensagem que o "Ver" abre, quando o item tem uma.
    let messageID: String?

    /// A cor do ponto do versalete, por família de objeto.
    @MainActor
    func dot(_ theme: Theme) -> TokenColor {
        switch kind {
        case .email: theme.info
        case .meeting: theme.warning
        case .promise: theme.accentInk
        }
    }

    /// **Os itens do dia, no máximo três.**
    ///
    /// A ordem é a do desenho: primeiro quem espera, depois o que está perto
    /// no relógio, depois a promessa. `nowMinute` e `today` entram pela porta
    /// — nenhuma consulta ao relógio acontece aqui dentro, como no `DayPlan`.
    nonisolated static func items(
        plan: DayPlan,
        agenda: [AgendaItem],
        pending: [PendingItem],
        today: Date,
        nowMinute: Int,
        limit: Int = 3,
        calendar: Calendar = .current
    ) -> [MesaDayItem] {
        var itens: [MesaDayItem] = []
        if let email = emailItem(plan: plan, today: today, calendar: calendar) {
            itens.append(email)
        }
        if let reuniao = meetingItem(agenda: agenda, nowMinute: nowMinute) {
            itens.append(reuniao)
        }
        if let promessa = promiseItem(pending: pending, today: today, calendar: calendar) {
            itens.append(promessa)
        }
        return Array(itens.prefix(limit))
    }

    /// Quem espera há mais tempo. O herói do dia quando há um; sem herói, a
    /// primeira linha de "Esperando você".
    private nonisolated static func emailItem(
        plan: DayPlan, today: Date, calendar: Calendar
    ) -> MesaDayItem? {
        let linhas = plan.sections.first { $0.kind == .waitingOnYou }?.rows ?? []
        let escolhida = plan.hero.flatMap { heroi in
            linhas.first { $0.item.message.id == heroi.messageID }
        } ?? linhas.first
        guard let linha = escolhida else { return nil }
        let mensagem = linha.item.message
        let nome = DashboardFocus.personName(
            displayName: mensagem.from.name, address: mensagem.from.address
        ) ?? mensagem.from.display
        // Nunca negativo: um e-mail que chegou "amanhã" (relógio torto) não
        // espera há menos zero dias — a mesma guarda do Painel.
        let dias = max(0, calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: mensagem.receivedAt),
            to: calendar.startOfDay(for: today)
        ).day ?? 0)
        let caps: String = switch dias {
        case 0: L10n.tr("E-MAIL · DE HOJE")
        case 1: L10n.tr("E-MAIL · ESPERANDO DESDE ONTEM")
        default: L10n.tr("E-MAIL · ESPERANDO HÁ \(dias) DIAS")
        }
        return MesaDayItem(
            id: "email:\(mensagem.id)",
            kind: .email,
            caps: caps,
            title: nome,
            detail: mensagem.subject,
            verb: L10n.tr("Rascunhar a resposta"),
            ask: L10n.tr("Responde o \(nome) por mim"),
            messageID: mensagem.id
        )
    }

    /// O próximo compromisso de hoje que ainda não acabou.
    private nonisolated static func meetingItem(
        agenda: [AgendaItem], nowMinute: Int
    ) -> MesaDayItem? {
        let proximo = agenda
            .filter { $0.dayOffset == 0 && $0.endMinute > nowMinute }
            .min { $0.startMinute < $1.startMinute }
        guard let item = proximo else { return nil }
        let faltam = item.startMinute - nowMinute
        let caps = faltam > 0 && faltam < 60
            ? L10n.tr("AGENDA · DAQUI A \(faltam) MIN")
            : L10n.tr("AGENDA · ÀS \(MinuteFormat.clock(item.startMinute))")
        return MesaDayItem(
            id: "meeting:\(item.id)",
            kind: .meeting,
            caps: caps,
            title: item.title,
            detail: "\(MinuteFormat.clock(item.startMinute))–\(MinuteFormat.clock(item.endMinute))",
            verb: L10n.tr("Preparar a pauta"),
            ask: L10n.tr("Prepara a pauta de \(item.title)"),
            messageID: nil
        )
    }

    /// A promessa que vence primeiro. As sem prazo vão para o fim: o e-mail
    /// não disse quando, e ordená-las como "hoje" seria inventar o prazo.
    private nonisolated static func promiseItem(
        pending: [PendingItem], today: Date, calendar: Calendar
    ) -> MesaDayItem? {
        let ordenadas = pending.sorted { a, b in
            switch (a.dueDate, b.dueDate) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.id < b.id
            }
        }
        guard let promessa = ordenadas.first else { return nil }
        let quando = promessa.dueDate.map {
            PainelDoDiaModelo.dataCurta($0)
        } ?? ""
        return MesaDayItem(
            id: "promise:\(promessa.id)",
            kind: .promise,
            caps: L10n.tr("PROMESSA · SUA"),
            title: PainelDoDiaModelo.titulo(de: promessa.text),
            detail: quando,
            verb: L10n.tr("Começar"),
            ask: L10n.tr("Me ajuda com: \(PainelDoDiaModelo.titulo(de: promessa.text))"),
            messageID: nil
        )
    }
}

// MARK: - Os objetos da mesa

/// **O que a mesa tem em cima dela.**
///
/// A Mesa não desenha bolhas de conversa: ela desenha objetos. A pergunta é
/// um deles (a lasca de acento à direita), e cada coisa que o assistente
/// produz é outro — uma nota, um rascunho, um evento proposto, uma ação
/// proposta.
///
/// É um valor, e não um `switch` dentro da `View`, porque a pergunta "que
/// objeto esta resposta virou" é decisão de produto: é ela que decide se o
/// botão primário abre o compositor ou escreve na agenda.
enum MesaObject: Identifiable {

    /// O que a pessoa pediu.
    case asked(id: String, text: String, at: Date)
    /// Prosa do assistente.
    case note(id: String, text: String, receipt: AssistantRunReceipt?)
    /// Um rascunho de e-mail. Com cartão, o primário abre o compositor pela
    /// mesma fila da Caixa; sem cartão (um turno de `draftReply`) sobra o
    /// texto e o "Copiar".
    case draft(id: String, text: String, card: AssistantProposalCard?)
    /// Um compromisso proposto.
    case event(id: String, card: AssistantProposalCard)
    /// Qualquer outra proposta — arquivar, sinalizar, aprender remetente.
    case proposal(id: String, card: AssistantProposalCard)

    var id: String {
        switch self {
        case let .asked(id, _, _): "asked:\(id)"
        case let .note(id, _, _): "note:\(id)"
        case let .draft(id, _, _): "draft:\(id)"
        case let .event(id, _): "event:\(id)"
        case let .proposal(id, _): "proposal:\(id)"
        }
    }

    /// O cartão por trás do objeto, quando há um.
    var card: AssistantProposalCard? {
        switch self {
        case let .draft(_, _, card): card
        case let .event(_, card), let .proposal(_, card): card
        case .asked, .note: nil
        }
    }

    /// **Que objeto um cartão é.** Decidido pelos efeitos, não pelo verbo: é
    /// o efeito que diz o que o clique faz, e o botão primário precisa dizer
    /// a verdade sobre ele.
    static func kind(
        for card: AssistantProposalCard, id: String
    ) -> MesaObject {
        for efeito in card.effects {
            if case let .prepareReply(_, texto) = efeito {
                let limpo = texto.trimmingCharacters(in: .whitespacesAndNewlines)
                if !limpo.isEmpty { return .draft(id: id, text: limpo, card: card) }
            }
        }
        for efeito in card.effects {
            switch efeito {
            case .addToAgenda, .reserveBlock: return .event(id: id, card: card)
            default: continue
            }
        }
        return .proposal(id: id, card: card)
    }

    /// A mesa de uma conversa inteira, na ordem em que as coisas chegaram.
    ///
    /// O recibo é da **última** ida e só a última resposta pode reivindicá-lo:
    /// pendurá-lo em turnos antigos faria a tela dizer que aqueles passos
    /// aconteceram agora.
    static func table(
        for messages: [AssistantMessage], lastReceipt: AssistantRunReceipt?
    ) -> [MesaObject] {
        var objetos: [MesaObject] = []
        for turno in messages {
            let ultimo = turno.id == messages.last?.id
            switch turno.speaker {
            case .user:
                objetos.append(
                    .asked(id: turno.id.uuidString, text: turno.text, at: turno.at)
                )
            case .assistant:
                if turno.kind == .draft {
                    objetos.append(
                        .draft(id: turno.id.uuidString, text: turno.text, card: nil)
                    )
                } else {
                    // **Prosa vazia não vira objeto.** Um modelo que devolve
                    // só propostas deixaria uma caixa NOTA com nada dentro —
                    // e caixa vazia na mesa é sujeira, não informação. O
                    // recibo, se houver, encosta no objeto seguinte.
                    let limpo = turno.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !limpo.isEmpty {
                        objetos.append(
                            .note(
                                id: turno.id.uuidString,
                                text: limpo,
                                receipt: ultimo ? lastReceipt : nil
                            )
                        )
                    }
                }
                for cartao in turno.cards {
                    objetos.append(kind(for: cartao, id: cartao.id))
                }
            }
        }
        return objetos
    }
}

// MARK: - A lasca que mede o próprio texto

/// **`max-width: 440px`, e não `width: 440px`.**
///
/// `.frame(maxWidth:)` do SwiftUI *fixa* a largura: uma pergunta de cinco
/// palavras virava uma faixa de 440 com texto num canto só, que não é o que o
/// desenho mostra. Este `Layout` oferece ao filho no máximo `limit` e devolve
/// **a largura que ele de fato usou** — a conta que o CSS faz.
struct MesaHugsText: Layout {

    let limit: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout Void
    ) -> CGSize {
        guard let unico = subviews.first else { return .zero }
        let largura = min(limit, proposal.width ?? limit)
        return unico.sizeThatFits(ProposedViewSize(width: largura, height: nil))
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void
    ) {
        subviews.first?.place(
            at: CGPoint(x: bounds.minX, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}

// MARK: - A mesa, o fundo pontilhado

/// `background-image: radial-gradient(dots 1px, transparent 1px);
/// background-size: 22px 22px` — a superfície onde os objetos assentam.
///
/// Os 28 temas usam o mesmo desenho: o ponto é `theme.line`, que é a hairline
/// do tema. Nenhuma bifurcação por vidro.
struct MesaDots: View {

    @Environment(\.theme) private var theme

    var body: some View {
        Canvas { context, size in
            let cor = theme.line.color
            let passo = MesaMetrics.dotSpacing
            let raio = MesaMetrics.dotRadius
            var y = passo / 2
            while y < size.height {
                var x = passo / 2
                while x < size.width {
                    context.fill(
                        Path(
                            ellipseIn: CGRect(
                                x: x - raio, y: y - raio, width: raio * 2, height: raio * 2
                            )
                        ),
                        with: .color(cor)
                    )
                    x += passo
                }
                y += passo
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - O versalete de um objeto

/// "✦ RASCUNHO" / "● EVENTO · PROPOSTO" — o cabeçalho mono de um objeto.
struct MesaCaps: View {

    @Environment(\.theme) private var theme

    let text: String
    /// O ✦ do objeto que a IA assinou. Sem ele, o ponto colorido do desenho.
    var sparkle = true
    var tint: TokenColor?
    /// A cor do ponto, quando ela não é a da tinta — o laranja do evento.
    var dot: TokenColor?

    private var cor: TokenColor { tint ?? theme.accentInk }

    var body: some View {
        HStack(spacing: 7) {
            if sparkle {
                Image(systemName: "sparkle")
                    .font(.system(size: MesaMetrics.capsGlyph, weight: .semibold))
                    .foregroundStyle(cor.color)
                    .accessibilityHidden(true)
            } else {
                Circle()
                    .fill((dot ?? cor).color)
                    .frame(width: MesaMetrics.capsDot, height: MesaMetrics.capsDot)
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(theme.mono.font(size: MesaMetrics.capsSize, weight: .semibold))
                .tracking(MesaMetrics.capsSize * MesaMetrics.capsTracking)
                .foregroundStyle(cor.color)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Os botões do desenho

/// O botão cheio: acento, tinta sobre acento, `box-shadow` só no vidro (no
/// tema clássico o desenho escreve `none`).
struct MesaPrimaryButton: View {

    @Environment(\.theme) private var theme

    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(theme.sans.font(size: MesaMetrics.primarySize, weight: .semibold))
                .foregroundStyle(theme.onAccent.color)
                .lineLimit(1)
                .fixedSize()
                .padding(MesaMetrics.primaryPadding)
                .background(theme.accent.color)
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                .contentShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
        .shadow(
            color: theme.isTranslucent ? theme.accent.color.opacity(0.28) : .clear,
            radius: 7, y: 4
        )
    }
}

/// O botão macio: `accentSoft` de fundo e o verbo em `accentInk`.
struct MesaSoftButton: View {

    @Environment(\.theme) private var theme

    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(theme.sans.font(size: MesaMetrics.primarySize, weight: .semibold))
                .foregroundStyle(theme.accentInk.color)
                .lineLimit(1)
                .fixedSize()
                .padding(MesaMetrics.primaryPadding)
                .background(theme.accentSoft.color)
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                .contentShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
    }
}

/// O botão com moldura: `border: 1px solid line`, verbo em `ink2`.
struct MesaOutlineButton: View {

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let title: String
    var padding = MesaMetrics.secondaryPadding
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(theme.sans.font(size: MesaMetrics.primarySize, weight: .medium))
                .foregroundStyle(theme.ink2.color)
                .lineLimit(1)
                .fixedSize()
                .padding(padding)
                .overlay {
                    RoundedRectangle(cornerRadius: theme.radiusSmall)
                        .strokeBorder(theme.line2.color, lineWidth: Hairline.thickness(displayScale))
                }
                .contentShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
    }
}

/// O botão sem caixa: só a tinta. É o "Abrir o anexo" e o "Copiar" do desenho.
struct MesaPlainButton: View {

    @Environment(\.theme) private var theme

    let title: String
    var size: CGFloat = MesaMetrics.primarySize
    var tint: TokenColor?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(theme.sans.font(size: size, weight: .semibold))
                .foregroundStyle((tint ?? theme.accentInk).color)
                .lineLimit(1)
                .fixedSize()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
    }
}

// MARK: - O objeto, desenhado

/// Um objeto da mesa: a caixa do desenho com versalete, corpo e ações.
///
/// Nunca há caixa dentro de caixa: o objeto **é** a caixa, e o que mora dentro
/// dele é texto e botão.
struct MesaObjectView: View {

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let object: MesaObject
    let session: AssistantSession
    let onRun: (AssistantProposalCard) -> Void
    let onReveal: (String) -> Void

    private var isDone: Bool {
        object.card.map { session.isDone($0.id) } ?? false
    }

    var body: some View {
        switch object {
        case let .asked(_, texto, _):
            asked(texto)
        case let .note(_, texto, recibo):
            card(
                caps: MesaCopy.note,
                accented: true,
                body: {
                    VStack(alignment: .leading, spacing: MesaMetrics.objectBodyGap) {
                        // Prosa de conversa passa pelo Markdown: o modelo
                        // escreve listas, e "- A Marina espera…" cru na tela é
                        // o traço aparecendo em vez do item.
                        AssistantMarkdown(
                            text: texto,
                            style: .prose(size: MesaMetrics.objectProseSize)
                        )
                        if let recibo, !recibo.isEmpty {
                            AssistantReceiptRow(receipt: recibo)
                        }
                    }
                },
                actions: {
                    HStack(spacing: MesaMetrics.objectActionGap) {
                        MesaOutlineButton(title: MesaCopy.copy) { copie(texto) }
                        Spacer(minLength: 0)
                    }
                }
            )
        case let .draft(_, texto, cartao):
            card(
                caps: MesaCopy.draft,
                accented: true,
                body: { prose(texto) },
                actions: {
                    HStack(spacing: MesaMetrics.objectActionGap) {
                        if let cartao {
                            if isDone {
                                doneRow
                            } else {
                                // "Abrir no compositor" é a verdade sobre o
                                // clique: ele grava o rascunho pela fila da
                                // Caixa e abre a janela da resposta. Nada sai
                                // sem revisão — ver `runProposalCard`.
                                MesaPrimaryButton(title: MesaCopy.openInComposer) {
                                    onRun(cartao)
                                }
                            }
                        }
                        MesaOutlineButton(title: MesaCopy.copy) { copie(texto) }
                        Spacer(minLength: 0)
                    }
                }
            )
        case let .event(_, cartao):
            card(
                caps: MesaCopy.event,
                accented: false,
                body: { titulo(cartao) },
                actions: { acoes(cartao, primary: MesaCopy.addToAgenda, soft: true) },
                // O ponto do versalete de evento é laranja no desenho. O token
                // semântico que vale nos 28 temas é `warning`.
                dot: theme.warning,
                hasBody: temCorpo(cartao)
            )
        case let .proposal(_, cartao):
            card(
                caps: MesaCopy.proposal,
                accented: false,
                body: { titulo(cartao) },
                actions: { acoes(cartao, primary: cartao.verb, soft: true) },
                hasBody: temCorpo(cartao)
            )
        }
    }

    // MARK: Pedaços

    /// O título do objeto e o porquê, quando a proposta traz um.
    private func titulo(_ cartao: AssistantProposalCard) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !cartao.displayText.isEmpty {
                Text(cartao.displayText)
                    .font(theme.sans.font(
                        size: MesaMetrics.objectTitleSize, weight: .semibold
                    ))
                    .foregroundStyle(theme.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !cartao.rationale.isEmpty {
                Text(cartao.rationale)
                    .font(theme.sans.font(size: MesaMetrics.objectSubSize))
                    .foregroundStyle(theme.ink3.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func temCorpo(_ cartao: AssistantProposalCard) -> Bool {
        !cartao.displayText.isEmpty || !cartao.rationale.isEmpty
    }

    /// A lasca de acento à direita: `max-width: 440px`, `accentSoft` de fundo.
    private func asked(_ text: String) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            MesaHugsText(limit: MesaMetrics.askedMaxWidth) {
                Text(text)
                    .font(theme.sans.font(size: MesaMetrics.askedSize))
                    .lineSpacing(MesaMetrics.askedSize * (MesaMetrics.askedLineHeight - 1.2))
                    .foregroundStyle(theme.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(MesaMetrics.askedPaddingInner)
            }
            .background(theme.accentSoft.color)
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusLarge))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.tr("Você: \(text)"))
    }

    private func prose(_ text: String) -> some View {
        Text(text)
            .font(theme.sans.font(size: MesaMetrics.objectProseSize))
            .lineSpacing(
                MesaMetrics.objectProseSize * (MesaMetrics.objectProseLineHeight - 1.2)
            )
            .foregroundStyle(theme.ink2.color)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func acoes(
        _ cartao: AssistantProposalCard, primary: String, soft: Bool
    ) -> some View {
        HStack(spacing: MesaMetrics.objectActionGap) {
            if isDone {
                doneRow
            } else if soft {
                MesaSoftButton(title: primary) { onRun(cartao) }
            } else {
                MesaPrimaryButton(title: primary) { onRun(cartao) }
            }
            if let secundario = cartao.secondary, let alvo = cartao.secondaryMessageID {
                MesaOutlineButton(title: secundario) { onReveal(alvo) }
            }
            Spacer(minLength: 0)
        }
    }

    private var doneRow: some View {
        HStack(spacing: MesaMetrics.objectActionGap) {
            Text(AssistantDrawerCopy.done)
                .font(theme.sans.font(size: MesaMetrics.primarySize, weight: .semibold))
                .foregroundStyle(theme.ink3.color)
            if session.hasUndo {
                Text(AssistantDrawerCopy.undo)
                    .font(theme.sans.font(size: MesaMetrics.primarySize, weight: .semibold))
                    .foregroundStyle(theme.accentInk.color)
                    .accessibilityLabel(L10n.tr("Desfazer pela barra de retorno"))
            }
        }
    }

    /// A caixa do objeto: versalete, fio, corpo, fio, ações.
    private func card<B: View, A: View>(
        caps: String,
        accented: Bool,
        @ViewBuilder body: () -> B,
        @ViewBuilder actions: () -> A,
        dot: TokenColor? = nil,
        /// O corpo tem o que dizer? Uma proposta sem frase nenhuma (o modelo
        /// devolveu só a ação) não pode abrir um vão em branco no objeto.
        hasBody: Bool = true
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MesaCaps(
                text: caps, sparkle: accented,
                tint: accented ? nil : theme.ink3, dot: dot
            )
                .padding(MesaMetrics.objectHeaderPadding)
                .hairline(theme.line, edges: .bottom)
            if hasBody {
                body()
                    .padding(MesaMetrics.objectBodyPadding)
            }
            // Sem corpo, o fio da fileira de ações encostaria no fio do
            // cabeçalho: dois traços colados, que é o desenho gaguejando.
            actions()
                .padding(MesaMetrics.objectActionPadding)
                .hairline(theme.line, edges: hasBody ? .top : [])
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.glassCard.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusLarge))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusLarge)
                .strokeBorder(
                    (accented ? theme.accentLine : theme.glassCardEdge).color,
                    lineWidth: Hairline.thickness(displayScale)
                )
        }
        // `box-shadow: 0 12px 30px rgba(0,0,0,.4)` — e `none` no clássico.
        .shadow(
            color: theme.isTranslucent ? .black.opacity(theme.isDark ? 0.40 : 0.10) : .clear,
            radius: 15, y: 6
        )
        .accessibilityElement(children: .contain)
    }

    private func copie(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Um objeto do dia

/// O item do dia desenhado como objeto da mesa: versalete com o ponto da
/// família, quem/o quê, e o verbo do desenho.
///
/// O botão **não executa nada**: ele manda a pergunta ao assistente, que é o
/// que o desenho promete ("Rascunhar a resposta" abre a conversa que escreve
/// o rascunho). Quem executa continua sendo o objeto que voltar da resposta.
struct MesaDayItemView: View {

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let item: MesaDayItem
    let onAsk: (String) -> Void
    let onReveal: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MesaCaps(text: item.caps, sparkle: false, tint: theme.ink3, dot: item.dot(theme))
                .padding(MesaMetrics.objectHeaderPadding)
                .hairline(theme.line, edges: .bottom)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(theme.sans.font(
                        size: MesaMetrics.objectTitleSize, weight: .semibold
                    ))
                    .foregroundStyle(theme.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(theme.sans.font(size: MesaMetrics.objectSubSize))
                        .foregroundStyle(theme.ink3.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(MesaMetrics.objectBodyPadding)
            HStack(spacing: MesaMetrics.objectActionGap) {
                MesaSoftButton(title: item.verb) { onAsk(item.ask) }
                if let id = item.messageID {
                    MesaOutlineButton(title: L10n.tr("Ver")) { onReveal(id) }
                }
                Spacer(minLength: 0)
            }
            .padding(MesaMetrics.objectActionPadding)
            .hairline(theme.line, edges: .top)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.glassCard.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusLarge))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusLarge)
                .strokeBorder(
                    theme.glassCardEdge.color, lineWidth: Hairline.thickness(displayScale)
                )
        }
        .shadow(
            color: theme.isTranslucent ? .black.opacity(theme.isDark ? 0.40 : 0.10) : .clear,
            radius: 15, y: 6
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.caps). \(item.title). \(item.detail)")
    }
}

// MARK: - As sugestões, em linha

/// As perguntas de partida, no idioma do desenho: **linha com seta, sem
/// caixa**.
///
/// Uma peça só, usada pela mesa vazia e pelo pé de uma resposta. Elas eram
/// pastilhas com moldura depois da resposta — ou seja, chips, que a casa não
/// usa; o desenho desenha as duas no mesmo formato, e agora elas são a mesma
/// view.
struct MesaSuggestionRows: View {

    @Environment(\.theme) private var theme

    let suggestions: [String]
    let isDisabled: Bool
    let onAsk: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(suggestions, id: \.self) { texto in
                Button { onAsk(texto) } label: {
                    HStack(spacing: MesaMetrics.suggestionGap) {
                        Image(systemName: "arrow.right")
                            .font(.system(
                                size: MesaMetrics.suggestionGlyph, weight: .semibold
                            ))
                            .foregroundStyle(theme.accentInk.color)
                        Text(texto)
                            .font(theme.sans.font(size: MesaMetrics.suggestionSize))
                            .foregroundStyle(theme.ink2.color)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(MesaMetrics.suggestionRowPadding)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusRing(cornerRadius: theme.radiusSmall)
                .disabled(isDisabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - O cabeçalho

/// "Assistente … ● Codex · neste Mac · trocar" — a barra da janela da Mesa.
///
/// Os semáforos são os **do sistema**, e a regra deles é a da casa:
/// `trafficLightsInWindowHeader()`, altura `TrafficLightLayout.windowBarHeight`
/// e o conteúdo a partir de `TrafficLightLayout.windowContentInset`. O desenho
/// pinta três bolinhas porque lá não existe janela de verdade.
struct MesaWindowHeader: View {

    @Environment(\.theme) private var theme

    let conversation: AssistantConversation
    let context: AssistantDrawerContext
    let onSwapContext: () -> Void

    private var destinationLabel: String {
        let destino = conversation.destination
        let detalhe = destino.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return detalhe.isEmpty ? destino.label : "\(destino.label) · \(detalhe)"
    }

    var body: some View {
        HStack(spacing: MesaMetrics.headerGap) {
            Text(AssistantDrawerCopy.title)
                .font(theme.sans.font(size: MesaMetrics.titleSize, weight: .semibold))
                .foregroundStyle(theme.ink.color)
                .fixedSize()
            Text(context.label)
                .font(theme.sans.font(size: MesaMetrics.routeSize))
                .foregroundStyle(theme.ink3.color)
                .lineLimit(1)
            Spacer(minLength: MesaMetrics.headerGap)
            Circle()
                .fill((conversation.destination.isLocal ? theme.success : theme.accent).color)
                .frame(width: MesaMetrics.routeDot, height: MesaMetrics.routeDot)
                .accessibilityHidden(true)
            Text(destinationLabel)
                .font(theme.sans.font(size: MesaMetrics.routeSize))
                .foregroundStyle(theme.ink3.color)
                .lineLimit(1)
                .truncationMode(.tail)
            Button(action: onSwapContext) {
                Text(AssistantDrawerCopy.swapLabel)
                    .font(theme.sans.font(size: MesaMetrics.swapSize, weight: .medium))
                    .foregroundStyle(theme.accentInk.color)
                    .fixedSize()
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusRing(cornerRadius: theme.radiusSmall)
            .accessibilityLabel(L10n.tr("Trocar o contexto da conversa"))
        }
        .padding(.leading, TrafficLightLayout.windowContentInset)
        .padding(.trailing, MesaMetrics.headerTrailing)
        .frame(height: TrafficLightLayout.windowBarHeight)
        .trafficLightsInWindowHeader()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("Falando sobre \(context.label)"))
    }
}

/// "✦ Assistente … ⌘J ↗ ✕" — o cabeçalho da gaveta, que **não** é barra de
/// janela: aqui não há semáforos para alinhar, e mexer nos da janela principal
/// moveria os botões de outra tela.
struct MesaDrawerHeader: View {

    @Environment(\.theme) private var theme

    let context: AssistantDrawerContext
    let onSwapContext: () -> Void
    let onDetach: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: MesaMetrics.headerGap) {
            Image(systemName: "sparkle")
                .font(.system(size: MesaMetrics.drawerGlyph, weight: .semibold))
                .foregroundStyle(theme.accentInk.color)
                .accessibilityHidden(true)
            Text(AssistantDrawerCopy.title)
                .font(theme.sans.font(size: MesaMetrics.drawerTitleSize, weight: .semibold))
                .foregroundStyle(theme.ink.color)
                .fixedSize()
            Button(action: onSwapContext) {
                Text(context.label)
                    .font(theme.sans.font(size: MesaMetrics.routeSize))
                    .foregroundStyle(theme.ink3.color)
                    .lineLimit(1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusRing(cornerRadius: theme.radiusSmall)
            .accessibilityLabel(L10n.tr("Trocar o contexto da conversa"))
            Spacer(minLength: MesaMetrics.headerGap)
            Text("⌘J")
                .font(theme.mono.font(size: MesaMetrics.drawerHintSize))
                .foregroundStyle(theme.ink4.color)
                .accessibilityHidden(true)
            action("arrow.up.forward.square", L10n.tr("Destacar em janela"), onDetach)
            action("xmark", L10n.tr("Fechar o assistente"), onClose)
        }
        .padding(MesaMetrics.drawerHeaderPadding)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("Falando sobre \(context.label)"))
    }

    private func action(
        _ symbol: String, _ label: String, _ run: @escaping () -> Void
    ) -> some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(.system(size: MesaMetrics.drawerActionGlyph, weight: .medium))
                .foregroundStyle(theme.ink3.color)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
        .accessibilityLabel(label)
    }
}

// MARK: - O campo

/// O campo do pé: `padding: 10px 10px 10px 14px`, "⌘J" em mono e o botão ↑ de
/// 30 em acento cheio.
struct MesaAskField: View {

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let conversation: AssistantConversation
    var focused: FocusState<Bool>.Binding
    /// A gaveta aperta o campo — ver `MesaMetrics.drawerFieldPadding`.
    var compact = false

    private var draft: Binding<String> {
        Binding(get: { conversation.draft }, set: { conversation.draft = $0 })
    }

    private var side: CGFloat {
        compact ? MesaMetrics.drawerSendSide : MesaMetrics.sendSide
    }

    var body: some View {
        HStack(spacing: MesaMetrics.fieldGap) {
            TextField(AssistantDrawerCopy.placeholder, text: draft)
                .textFieldStyle(.plain)
                .font(theme.sans.font(size: MesaMetrics.fieldTextSize))
                .foregroundStyle(theme.ink.color)
                .focused(focused)
                // ⏎ **manda a pergunta**, e nada mais. Nenhuma proposta é
                // executada por tecla.
                .onSubmit { conversation.submit() }
                .accessibilityLabel(AssistantDrawerCopy.placeholder)
            if !compact {
                Text("⌘J")
                    .font(theme.mono.font(size: MesaMetrics.fieldHintSize))
                    .foregroundStyle(theme.ink4.color)
                    .accessibilityHidden(true)
            }
            Button(action: conversation.submit) {
                Image(systemName: "arrow.up")
                    .font(.system(size: MesaMetrics.sendGlyph, weight: .bold))
                    .foregroundStyle(theme.onAccent.color)
                    .frame(width: side, height: side)
                    .background(theme.accent.color)
                    .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
            }
            .buttonStyle(.plain)
            .focusRing(cornerRadius: theme.radiusSmall)
            .disabled(!conversation.canSend)
            .accessibilityLabel(L10n.tr("Mandar a pergunta"))
        }
        .padding(compact ? MesaMetrics.drawerFieldPadding : MesaMetrics.fieldPadding)
        .background(theme.surface2.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusLarge))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusLarge)
                .strokeBorder(theme.btnLine.color, lineWidth: Hairline.thickness(displayScale))
        }
        .padding(compact ? MesaMetrics.drawerFieldMargin : MesaMetrics.fieldMargin)
    }
}

// MARK: - Os passos visíveis

/// Os passos de uma ida ao motor: os cumpridos com ✓, o em curso com o ponto
/// que pulsa. Nenhuma linha "pendente" — o app não sabe qual é o próximo
/// passo, e desenhar um seria inventar.
struct MesaSteps: View {

    @Environment(\.theme) private var theme

    let steps: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: MesaMetrics.stepGap) {
            ForEach(Array(steps.enumerated()), id: \.offset) { indice, passo in
                if indice == steps.count - 1 {
                    HStack(spacing: 7) {
                        MesaPulseDot()
                        Text(passo)
                            .font(theme.mono.font(size: MesaMetrics.stepSize, weight: .medium))
                            .foregroundStyle(theme.accentInk.color)
                        Spacer(minLength: 0)
                    }
                } else {
                    AssistantStepCheck(
                        text: passo,
                        size: MesaMetrics.stepSize,
                        glyph: MesaMetrics.stepGlyph
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.tr("Respondendo à pergunta"))
    }
}

/// `dotPulse`: o ponto de acento que respira enquanto o motor trabalha.
struct MesaPulseDot: View {

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.movimentoParado) private var movimentoParado

    private var reduceMotion: Bool { systemReduceMotion || movimentoParado }

    var side: CGFloat = MesaMetrics.stepDot

    @State private var dim = false

    var body: some View {
        Circle()
            .fill(theme.accent.color)
            .frame(width: side, height: side)
            .opacity(dim ? 0.45 : 1)
            .animation(reduceMotion ? nil : MesaMetrics.dotPulse, value: dim)
            .onAppear { if !reduceMotion { dim = true } }
            .accessibilityHidden(true)
    }
}

/// `.skel`: a barra que varre, para o objeto que ainda está nascendo.
struct MesaSkeletonBar: View {

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.movimentoParado) private var movimentoParado

    private var reduceMotion: Bool { systemReduceMotion || movimentoParado }

    var height: CGFloat = 12
    var fraction: CGFloat = 1

    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { proxy in
            let largura = proxy.size.width * fraction
            // `skelBase` do desenho: 6% de tinta sobre a superfície, nos dois
            // vidros e nos 26 opacos. `surface3` fica perto demais do papel no
            // vidro claro e a barra sumia.
            RoundedRectangle(cornerRadius: height / 2)
                .fill(theme.glassSoft.color)
                .frame(width: largura, height: height)
                .overlay {
                    if !reduceMotion {
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: theme.line2.color, location: 0.5),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: largura)
                        .offset(x: phase * largura)
                        .frame(width: largura, alignment: .leading)
                        .clipped()
                        .animation(MesaMetrics.skeletonSweep, value: phase)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: height / 2))
        }
        .frame(height: height)
        .onAppear { if !reduceMotion { phase = 1 } }
        .accessibilityHidden(true)
    }
}

/// O objeto que ainda está sendo escrito: moldura tracejada, versalete e as
/// barras que varrem. É o "CONVITE · MONTANDO" do desenho.
struct MesaBirthingObject: View {

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let caps: String

    var body: some View {
        VStack(alignment: .leading, spacing: MesaMetrics.objectBodyGap) {
            MesaCaps(text: caps, sparkle: false, tint: theme.ink4)
            MesaSkeletonBar(height: 24, fraction: 1)
            MesaSkeletonBar(height: 12, fraction: 0.66)
        }
        .padding(MesaMetrics.objectBodyPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusLarge)
                .strokeBorder(
                    theme.line2.color,
                    style: StrokeStyle(
                        lineWidth: Hairline.thickness(displayScale), dash: [4, 4]
                    )
                )
        }
        .opacity(0.8)
        .accessibilityHidden(true)
    }
}
