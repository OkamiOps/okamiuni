import SwiftUI
import UNICore
import UNIDesign

/// As medidas da direção **Presença** — `design/IA-Presenca.dc.html`, lidas
/// valor por valor dos estilos em linha do desenho.
///
/// Mora fora de qualquer `View` pelo motivo de sempre: uma `View` é
/// `@MainActor` implícito e um `static` lá dentro estoura quando um teste
/// `nonisolated` o lê.
enum PresencaMetrics {

    /// A janela do desenho: `width: 880px; height: 744px`.
    static let windowSize = CGSize(width: 880, height: 744)

    // MARK: Cabeçalho — `padding: 13px 18px; gap: 10px`

    static let headerPadding = EdgeInsets(top: 13, leading: 18, bottom: 13, trailing: 18)
    static let headerGap: CGFloat = 10
    /// `width: 20px; height: 20px` do orbe do cabeçalho.
    static let headerOrb: CGFloat = 20
    static let titleSize: CGFloat = 13.5
    static let contextSize: CGFloat = 12.5
    static let swapSize: CGFloat = 12
    static let modelSize: CGFloat = 11

    // MARK: A pergunta — `padding: 22px 44px 0; gap: 12px`

    static let questionTop: CGFloat = 22
    static let questionGap: CGFloat = 12
    /// `font-size: 10.5px; letter-spacing: 0.08em` do "VOCÊ · 16:02".
    static let stampSize: CGFloat = 10.5
    static let stampTracking: CGFloat = 0.08
    static let questionSize: CGFloat = 14

    // MARK: O briefing — `padding: 16px 44px 0; gap: 16px`

    /// `padding: … 44px …` na janela. A gaveta é estreita e usa 20, que é o
    /// recuo que ela já tinha: o desenho não tem artboard de gaveta, e manter
    /// 44 num painel de 440 deixaria 352 de texto.
    static func gutter(forWidth width: CGFloat) -> CGFloat { width >= 700 ? 44 : 20 }

    static let briefingTop: CGFloat = 16
    static let briefingGap: CGFloat = 16
    /// `font-size: 27px; font-weight: 700; letter-spacing: -0.02em;
    /// line-height: 1.18`.
    static let headlineSize: CGFloat = 27
    static let headlineTracking: CGFloat = -0.02
    static let headlineLineHeight: CGFloat = 1.18
    /// A prosa que sobra depois da manchete.
    static let proseSize: CGFloat = 14

    /// Recibo dos passos — `gap: 14px; font-size: 11.5px`, visto 11px.
    static let receiptGap: CGFloat = 14
    static let receiptSize: CGFloat = 11.5
    static let receiptItemGap: CGFloat = 5
    static let receiptCheck: CGFloat = 11

    /// Itens — `grid-template-columns: 54px minmax(0,1fr) auto; gap: 8px`.
    static let numberColumn: CGFloat = 54
    static let itemGap: CGFloat = 8
    /// `font-size: 24px; font-weight: 600` do "01".
    static let numberSize: CGFloat = 24
    /// O item aberto: `gap: 9px` na coluna da direita.
    static let openItemGap: CGFloat = 9
    static let openTitleSize: CGFloat = 16
    static let itemTitleSize: CGFloat = 15
    static let itemSubSize: CGFloat = 13
    static let itemTitleGap: CGFloat = 10
    /// O botão do item fechado: `padding: 7px 13px; font-size: 12.5px`.
    static let itemButtonPadding = EdgeInsets(top: 7, leading: 13, bottom: 7, trailing: 13)
    static let itemButtonSize: CGFloat = 12.5

    /// O rascunho dentro do briefing — `border-left: 2px; padding: 2px 0 2px 16px; gap: 6px`.
    static let draftRule: CGFloat = 2
    static let draftIndent: CGFloat = 16
    static let draftGap: CGFloat = 6
    static let draftCapsSize: CGFloat = 10
    static let draftCapsTracking: CGFloat = 0.08
    static let draftBodySize: CGFloat = 14
    static let draftBodyLineHeight: CGFloat = 1.55
    static let draftActionGap: CGFloat = 8
    /// `padding: 8px 14px; font-size: 13px; font-weight: 600`.
    static let primaryPadding = EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
    static let primarySize: CGFloat = 13
    /// `padding: 7px 13px` no secundário com borda.
    static let secondaryPadding = EdgeInsets(top: 7, leading: 13, bottom: 7, trailing: 13)
    static let draftNoteSize: CGFloat = 12

    /// "pergunte mais:" — `gap: 10px; font-size: 13px`.
    static let followUpGap: CGFloat = 10
    static let followUpSize: CGFloat = 13

    // MARK: Trabalhando — `gap: 26px; padding: 0 60px`

    static let workingGap: CGFloat = 26
    static let workingPadding: CGFloat = 60
    /// O orbe grande: caixa 72, núcleo 58, anel a `inset: -14px`.
    static let bigOrbBox: CGFloat = 72
    static let bigOrbCore: CGFloat = 58
    static let bigOrbRingInset: CGFloat = 14
    static let workingTitleSize: CGFloat = 21
    static let workingTitleTracking: CGFloat = -0.015
    /// O cursor: `width: 10px; height: 22px; border-radius: 2px`.
    static let caretWidth: CGFloat = 10
    static let caretHeight: CGFloat = 22
    /// A lista de passos: `width: 340px; gap: 11px; font-size: 12.5px`.
    static let stepListWidth: CGFloat = 340
    static let stepGap: CGFloat = 11
    static let stepSize: CGFloat = 12.5
    static let stepGlyph: CGFloat = 13
    static let stepItemGap: CGFloat = 9

    // MARK: Campo — `margin: 14px 24px 8px; padding: 10px 10px 10px 14px`

    static let fieldMargin = EdgeInsets(top: 14, leading: 24, bottom: 8, trailing: 24)
    static let fieldPadding = EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 10)
    static let fieldGap: CGFloat = 10
    static let fieldOrb: CGFloat = 16
    static let fieldTextSize: CGFloat = 14
    static let fieldHintSize: CGFloat = 11
    static let sendSide: CGFloat = 32
    static let sendGlyph: CGFloat = 15
    /// `padding: 0 24px 14px; font-size: 11.5px`.
    static let footerSize: CGFloat = 11.5
    static let footerBottom: CGFloat = 14

    // MARK: Animações

    /// `orbGlow 3.2s ease-in-out infinite` — ida e volta, logo 1,6s por meia.
    static let orbPulse = Animation.easeInOut(duration: 1.6).repeatForever(autoreverses: true)
    /// `orbSpin 9s linear infinite`.
    static let orbSpin = Animation.linear(duration: 9).repeatForever(autoreverses: false)
    /// `shimTxt 1.8s linear infinite`.
    static let shimmer = Animation.linear(duration: 1.8).repeatForever(autoreverses: false)
    /// `caretBlink 1s steps(1) infinite` — meio segundo aceso, meio apagado,
    /// sem rampa (é o que `steps(1)` faz).
    static let caretBlink = Animation.linear(duration: 0.01)
        .delay(0.5).repeatForever(autoreverses: true)
}

/// **O movimento, parado.**
///
/// O desenho da Presença respira: o orbe pulsa, o anel gira, o cursor pisca e
/// o fio de tinta corre. Nada disso pode ser comparado em pixels — dois
/// quadros de uma animação nunca são o mesmo quadro —, e o harness de
/// renderização existe justamente para comparar pixels.
///
/// Esta chave é o que o harness liga. **Não é a preferência da pessoa**: essa
/// é `accessibilityReduceMotion`, que o sistema fornece e ninguém injeta, e
/// que vale igual. Qualquer uma das duas para o movimento.
private struct MovimentoParadoKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var movimentoParado: Bool {
        get { self[MovimentoParadoKey.self] }
        set { self[MovimentoParadoKey.self] = newValue }
    }
}

// MARK: - O orbe

/// A identidade viva da Presença: um orbe que respira.
///
/// O gradiente é o do desenho. No Vidro é literal — branco, lilás, violeta e
/// magenta, com halo; nos 26 temas opacos ele é construído do acento do tema
/// (que é o que o desenho faz no tema `classico`, em oklch sobre o laranja) e
/// **sem** halo, porque lá `orbGlow` é `none`.
struct AssistantOrb: View {

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.movimentoParado) private var movimentoParado

    /// Qualquer uma das duas para o movimento — ver `MovimentoParadoKey`.
    private var reduceMotion: Bool { systemReduceMotion || movimentoParado }

    let side: CGFloat
    /// O anel pontilhado que gira — só o estado "trabalhando" o desenha.
    var showsRing = false
    /// O halo. `nil` deixa a decisão para o tema (vidro sim, opaco não).
    var glow: CGFloat?

    @State private var pulsing = false
    @State private var spin = false

    private var stops: [Gradient.Stop] {
        if theme.isGlass {
            // `radial-gradient(circle at 32% 30%, #ffffff 0, #a9a3ff 28%,
            //  #6d63ff 58%, #d6498f 100%)`
            return [
                .init(color: .white, location: 0),
                .init(color: Color(red: 169 / 255, green: 163 / 255, blue: 255 / 255), location: 0.28),
                .init(color: Color(red: 109 / 255, green: 99 / 255, blue: 255 / 255), location: 0.58),
                .init(color: Color(red: 214 / 255, green: 73 / 255, blue: 143 / 255), location: 1),
            ]
        }
        // O mesmo desenho, nas cores do tema: claro no miolo, acento no meio,
        // acento escurecido na borda.
        return [
            .init(color: theme.accentInk.color.opacity(0.95), location: 0),
            .init(color: theme.accentInk.color, location: 0.28),
            .init(color: theme.accent.color, location: 0.58),
            .init(color: theme.accent.mixing(with: theme.paper, amount: 0.45).color, location: 1),
        ]
    }

    private var halo: CGFloat {
        glow ?? (theme.isGlass ? side * 0.6 : 0)
    }

    var body: some View {
        ZStack {
            if showsRing {
                Circle()
                    .strokeBorder(
                        theme.accentInk.color.opacity(0.4),
                        style: StrokeStyle(lineWidth: 1.5, dash: [4, 4])
                    )
                    .frame(
                        width: side + PresencaMetrics.bigOrbRingInset * 2,
                        height: side + PresencaMetrics.bigOrbRingInset * 2
                    )
                    .rotationEffect(.degrees(spin ? 360 : 0))
            }
            Circle()
                .fill(
                    RadialGradient(
                        stops: stops,
                        center: UnitPoint(x: 0.32, y: 0.30),
                        startRadius: 0,
                        endRadius: side * 0.72
                    )
                )
                .frame(width: side, height: side)
                .shadow(
                    color: halo > 0
                        ? Color(red: 132 / 255, green: 110 / 255, blue: 255 / 255).opacity(0.55)
                        : .clear,
                    radius: halo
                )
                .scaleEffect(pulsing ? 1.07 : 1)
        }
        .frame(
            width: showsRing ? side + PresencaMetrics.bigOrbRingInset * 2 : side,
            height: showsRing ? side + PresencaMetrics.bigOrbRingInset * 2 : side
        )
        .animation(reduceMotion ? nil : PresencaMetrics.orbPulse, value: pulsing)
        .animation(reduceMotion ? nil : PresencaMetrics.orbSpin, value: spin)
        .onAppear {
            guard !reduceMotion else { return }
            pulsing = true
            spin = true
        }
        .accessibilityHidden(true)
    }
}

// MARK: - O cursor que pisca

/// O `caret` do desenho: um bloco de acento que pisca em degraus.
struct AssistantCaret: View {

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.movimentoParado) private var movimentoParado

    /// Qualquer uma das duas para o movimento — ver `MovimentoParadoKey`.
    private var reduceMotion: Bool { systemReduceMotion || movimentoParado }

    var width: CGFloat = PresencaMetrics.caretWidth
    var height: CGFloat = PresencaMetrics.caretHeight

    @State private var on = false

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(theme.accentInk.color)
            .frame(width: width, height: height)
            .opacity(on ? 0 : 1)
            .animation(reduceMotion ? nil : PresencaMetrics.caretBlink, value: on)
            .onAppear { if !reduceMotion { on = true } }
            .accessibilityHidden(true)
    }
}

// MARK: - O passo em curso

/// `shim-txt`: a frase do passo atual com um brilho que a atravessa.
///
/// Com "Reduzir movimento" ligado o brilho não corre — o texto fica na tinta
/// clara do fim do gradiente, que é o que ele significa.
struct AssistantShimmerText: View {

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.movimentoParado) private var movimentoParado

    /// Qualquer uma das duas para o movimento — ver `MovimentoParadoKey`.
    private var reduceMotion: Bool { systemReduceMotion || movimentoParado }

    let text: String
    var size: CGFloat = PresencaMetrics.stepSize

    @State private var phase: CGFloat = -1

    private var label: Text {
        Text(text).font(theme.mono.font(size: size, weight: .medium))
    }

    var body: some View {
        label
            .foregroundStyle(reduceMotion ? theme.ink.color : theme.ink4.color)
            .overlay {
                if !reduceMotion {
                    GeometryReader { proxy in
                        let faixa = max(proxy.size.width, 1) * 1.6
                        LinearGradient(
                            stops: [
                                .init(color: theme.ink4.color, location: 0),
                                .init(color: theme.ink.color, location: 0.5),
                                .init(color: theme.ink4.color, location: 1),
                            ],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: faixa)
                        .offset(x: phase * faixa)
                        .frame(width: proxy.size.width, alignment: .leading)
                        .clipped()
                    }
                    .mask(label)
                    .animation(PresencaMetrics.shimmer, value: phase)
                }
            }
            .onAppear { if !reduceMotion { phase = 1 } }
    }
}

// MARK: - O fio de tinta

/// `ink-line`: o fio que a IA deixa, com o gradiente correndo por dentro.
/// É a assinatura da direção **Tinta**, e a Presença o usa como divisória.
struct AssistantInkLine: View {

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.movimentoParado) private var movimentoParado

    /// Qualquer uma das duas para o movimento — ver `MovimentoParadoKey`.
    private var reduceMotion: Bool { systemReduceMotion || movimentoParado }

    var height: CGFloat = 1.5

    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { proxy in
            let faixa = max(proxy.size.width, 1) * 2
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: theme.accent.color, location: 0.35),
                    .init(color: theme.accentInk.color, location: 0.55),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: faixa)
            .offset(x: reduceMotion ? -faixa / 4 : phase * faixa / 2)
            .frame(width: proxy.size.width, alignment: .leading)
            .clipped()
            .animation(reduceMotion ? nil : PresencaMetrics.shimmer, value: phase)
        }
        .frame(height: height)
        .onAppear { if !reduceMotion { phase = 1 } }
        .accessibilityHidden(true)
    }
}

// MARK: - O recibo dos passos

/// Um passo cumprido, com o ✓ do desenho.
struct AssistantStepCheck: View {

    @Environment(\.theme) private var theme

    let text: String
    var size: CGFloat = PresencaMetrics.receiptSize
    var glyph: CGFloat = PresencaMetrics.receiptCheck

    var body: some View {
        HStack(spacing: PresencaMetrics.receiptItemGap) {
            Image(systemName: "checkmark")
                .font(.system(size: glyph, weight: .bold))
                .foregroundStyle(theme.success.color)
                .accessibilityHidden(true)
            Text(text)
                .font(theme.mono.font(size: size))
                .foregroundStyle(theme.ink3.color)
        }
    }
}

/// A linha "li 12 e-mails de hoje · olhei a agenda · 2,4s".
///
/// **Só desenha passos que de fato aconteceram.** Sem ferramentas no caminho
/// (um provedor sem agente, uma preview) o recibo não existe e a linha some —
/// inventar "olhei a agenda" seria a tela mentindo sobre o trabalho.
struct AssistantReceiptRow: View {

    @Environment(\.theme) private var theme

    let receipt: AssistantRunReceipt

    var body: some View {
        HStack(spacing: PresencaMetrics.receiptGap) {
            ForEach(Array(receipt.steps.enumerated()), id: \.offset) { _, passo in
                AssistantStepCheck(text: passo)
            }
            if let decorrido = receipt.elapsedLabel {
                Text(decorrido)
                    .font(theme.mono.font(size: PresencaMetrics.receiptSize))
                    .foregroundStyle(theme.ink4.color)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - A pergunta

/// "VOCÊ · 16:02   O que eu preciso resolver antes das 18h?" — a pergunta como
/// linha de dossiê, sem balão.
struct AssistantQuestionLine: View {

    @Environment(\.theme) private var theme

    let text: String
    let at: Date

    private var stamp: String {
        let hora = at.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened, locale: L10n.locale)
        )
        return "\(L10n.tr("VOCÊ")) · \(hora)"
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PresencaMetrics.questionGap) {
            Text(stamp)
                .font(theme.mono.font(size: PresencaMetrics.stampSize, weight: .semibold))
                .tracking(PresencaMetrics.stampSize * PresencaMetrics.stampTracking)
                .foregroundStyle(theme.accentInk.color)
                .fixedSize()
            Text(text)
                .font(theme.sans.font(size: PresencaMetrics.questionSize))
                .foregroundStyle(theme.ink2.color)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.tr("Você: \(text)"))
    }
}

// MARK: - O rascunho dentro do briefing

/// O rascunho pronto, atracado ao item que o pediu: fio de acento à esquerda,
/// versalete, a prosa e os dois botões. Nada sai sem revisão — é o que a nota
/// ao lado dos botões promete, e é o que `prepareReply` faz.
struct AssistantInlineDraft: View {

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let draft: String
    let isDone: Bool
    let hasUndo: Bool
    /// O rótulo do botão primário — o verbo do cartão.
    let verb: String
    let onRun: () -> Void
    /// "Editar" abre o mesmo rascunho na janela, sem executar a leva.
    let onEdit: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle()
                .fill(theme.accent.color)
                .frame(width: PresencaMetrics.draftRule)
            VStack(alignment: .leading, spacing: PresencaMetrics.draftGap) {
                Text(L10n.tr("RASCUNHO PRONTO"))
                    .font(theme.mono.font(size: PresencaMetrics.draftCapsSize, weight: .semibold))
                    .tracking(PresencaMetrics.draftCapsSize * PresencaMetrics.draftCapsTracking)
                    .foregroundStyle(theme.accentInk.color)
                Text(draft)
                    .font(theme.sans.font(size: PresencaMetrics.draftBodySize))
                    .lineSpacing(PresencaMetrics.draftBodySize * (PresencaMetrics.draftBodyLineHeight - 1.2))
                    .foregroundStyle(theme.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(spacing: PresencaMetrics.draftActionGap) {
                    if isDone {
                        Text(AssistantDrawerCopy.done)
                            .font(theme.sans.font(size: PresencaMetrics.primarySize, weight: .semibold))
                            .foregroundStyle(theme.ink3.color)
                        if hasUndo {
                            Text(AssistantDrawerCopy.undo)
                                .font(theme.sans.font(size: PresencaMetrics.primarySize, weight: .semibold))
                                .foregroundStyle(theme.accentInk.color)
                                .accessibilityLabel(L10n.tr("Desfazer pela barra de retorno"))
                        }
                    } else {
                        PresencaPrimaryButton(title: verb, action: onRun)
                        if let onEdit {
                            PresencaOutlineButton(title: L10n.tr("Editar"), action: onEdit)
                        }
                    }
                    Text(L10n.tr("nada sai sem você rever"))
                        .font(theme.sans.font(size: PresencaMetrics.draftNoteSize))
                        .foregroundStyle(theme.ink4.color)
                        .lineLimit(1)
                }
                .padding(.top, 2)
            }
            .padding(.leading, PresencaMetrics.draftIndent)
            .padding(.vertical, 2)
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Os dois botões do desenho

struct PresencaPrimaryButton: View {

    @Environment(\.theme) private var theme

    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(theme.sans.font(size: PresencaMetrics.primarySize, weight: .semibold))
                .foregroundStyle(theme.onAccent.color)
                .padding(PresencaMetrics.primaryPadding)
                .background(theme.accent.color)
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                .contentShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
        // `box-shadow: 0 4px 14px rgba(…,0.28)` — e `none` no tema clássico.
        .shadow(
            color: theme.isGlass ? theme.accent.color.opacity(0.28) : .clear,
            radius: 7, y: 4
        )
    }
}

struct PresencaOutlineButton: View {

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(theme.sans.font(size: PresencaMetrics.primarySize, weight: .medium))
                .foregroundStyle(theme.ink2.color)
                .padding(PresencaMetrics.secondaryPadding)
                .overlay {
                    RoundedRectangle(cornerRadius: theme.radiusSmall)
                        .strokeBorder(theme.line.color, lineWidth: Hairline.thickness(displayScale))
                }
                .contentShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
    }
}

// MARK: - Um item do briefing

/// Um cartão de proposta como **item numerado** do briefing.
///
/// O item que traz rascunho abre: a prosa do rascunho mora dentro dele, como
/// no desenho. Os outros são uma linha — número, título, porquê e o verbo à
/// direita.
struct AssistantBriefingItem: View {

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let number: Int
    let card: AssistantProposalCard
    let isDone: Bool
    let hasUndo: Bool
    let onRun: () -> Void
    let onReveal: () -> Void

    /// O rascunho que o cartão carrega, quando ele prepara uma resposta.
    private var draft: String? {
        for efeito in card.effects {
            if case let .prepareReply(_, texto) = efeito {
                let limpo = texto.trimmingCharacters(in: .whitespacesAndNewlines)
                return limpo.isEmpty ? nil : limpo
            }
        }
        return nil
    }

    private var label: String {
        number < 10 ? "0\(number)" : "\(number)"
    }

    var body: some View {
        HStack(alignment: .top, spacing: PresencaMetrics.itemGap) {
            Text(label)
                .font(theme.mono.font(size: PresencaMetrics.numberSize, weight: .semibold))
                .foregroundStyle((draft == nil ? theme.ink4 : theme.accentInk).color)
                .frame(width: PresencaMetrics.numberColumn, alignment: .leading)
                .accessibilityHidden(true)
            if let draft {
                aberto(draft)
            } else {
                fechado
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityHint(card.rationale)
    }

    /// `gap: 9px`, título em 16/650 e o rascunho embaixo.
    private func aberto(_ draft: String) -> some View {
        VStack(alignment: .leading, spacing: PresencaMetrics.openItemGap) {
            HStack(alignment: .firstTextBaseline, spacing: PresencaMetrics.itemTitleGap) {
                Text(card.displayText)
                    .font(theme.sans.font(size: PresencaMetrics.openTitleSize, weight: .semibold))
                    .tracking(PresencaMetrics.openTitleSize * -0.01)
                    .foregroundStyle(theme.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
                if !card.rationale.isEmpty {
                    Text(card.rationale)
                        .font(theme.sans.font(size: PresencaMetrics.itemSubSize))
                        .foregroundStyle(theme.ink3.color)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            AssistantInlineDraft(
                draft: draft,
                isDone: isDone,
                hasUndo: hasUndo,
                verb: card.verb,
                onRun: onRun,
                onEdit: card.secondaryMessageID == nil ? nil : onReveal
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var fechado: some View {
        HStack(alignment: .firstTextBaseline, spacing: PresencaMetrics.itemGap) {
            VStack(alignment: .leading, spacing: 2) {
                Text(card.displayText)
                    .font(theme.sans.font(size: PresencaMetrics.itemTitleSize, weight: .semibold))
                    .tracking(PresencaMetrics.itemTitleSize * -0.01)
                    .foregroundStyle(theme.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
                if !card.rationale.isEmpty {
                    Text(card.rationale)
                        .font(theme.sans.font(size: PresencaMetrics.itemSubSize))
                        .foregroundStyle(theme.ink3.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: PresencaMetrics.itemGap)
            if isDone {
                HStack(spacing: PresencaMetrics.itemGap) {
                    Text(AssistantDrawerCopy.done)
                        .font(theme.sans.font(size: PresencaMetrics.itemButtonSize, weight: .semibold))
                        .foregroundStyle(theme.ink3.color)
                    if hasUndo {
                        Text(AssistantDrawerCopy.undo)
                            .font(theme.sans.font(size: PresencaMetrics.itemButtonSize, weight: .semibold))
                            .foregroundStyle(theme.accentInk.color)
                            .accessibilityLabel(L10n.tr("Desfazer pela barra de retorno"))
                    }
                }
            } else {
                Button(action: onRun) {
                    Text(card.verb)
                        .font(theme.sans.font(size: PresencaMetrics.itemButtonSize, weight: .semibold))
                        .foregroundStyle(theme.accentInk.color)
                        .padding(PresencaMetrics.itemButtonPadding)
                        .background(theme.surface3.color)
                        .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                        .overlay {
                            RoundedRectangle(cornerRadius: theme.radiusSmall)
                                .strokeBorder(theme.line.color, lineWidth: Hairline.thickness(displayScale))
                        }
                        .contentShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                        .fixedSize()
                }
                .buttonStyle(.plain)
                .focusRing(cornerRadius: theme.radiusSmall)
                .accessibilityLabel("\(card.verb): \(card.text)")
            }
        }
    }
}

// MARK: - O estado "trabalhando"

/// A presença pensando na frente da pessoa: orbe grande com anel, a frase com
/// cursor, e os passos que ela já deu.
///
/// Os passos são os **reais** — `AssistantSession` os acumula do mesmo
/// `onActivity` que a barra de trabalho do chrome já lia. O último está em
/// curso (brilho correndo); os anteriores levam ✓. Não há linha "pendente":
/// o app não sabe de antemão qual é o próximo passo, e desenhar um seria
/// inventar.
struct AssistantWorkingState: View {

    @Environment(\.theme) private var theme

    /// O que o motor está fazendo agora, e o que já fez.
    let steps: [String]
    /// A frase do alto — a legenda de carregamento da conversa.
    let title: String

    var body: some View {
        VStack(spacing: PresencaMetrics.workingGap) {
            AssistantOrb(side: PresencaMetrics.bigOrbCore, showsRing: true)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(title)
                    .font(theme.sans.font(size: PresencaMetrics.workingTitleSize, weight: .semibold))
                    .tracking(PresencaMetrics.workingTitleSize * PresencaMetrics.workingTitleTracking)
                    .foregroundStyle(theme.ink.color)
                    .multilineTextAlignment(.center)
                AssistantCaret()
                    .offset(y: 3)
            }
            if !steps.isEmpty {
                VStack(alignment: .leading, spacing: PresencaMetrics.stepGap) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { indice, passo in
                        if indice == steps.count - 1 {
                            HStack(spacing: PresencaMetrics.stepItemGap) {
                                AssistantOrb(side: PresencaMetrics.stepGlyph)
                                AssistantShimmerText(text: passo)
                                Spacer(minLength: 0)
                            }
                        } else {
                            AssistantStepCheck(
                                text: passo,
                                size: PresencaMetrics.stepSize,
                                glyph: PresencaMetrics.stepGlyph
                            )
                        }
                    }
                }
                .frame(width: PresencaMetrics.stepListWidth, alignment: .leading)
            }
        }
        .padding(.horizontal, PresencaMetrics.workingPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.tr("Respondendo à pergunta"))
    }
}
