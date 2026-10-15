import SwiftUI
import UNICore
import UNIDesign

/// As peças que a **Tinta** (a IA dentro do e-mail, `ReaderInkSection`) e a
/// **Mesa** (o assistente) dividem: o fio, o passo cumprido, o passo em curso
/// e os dois botões do desenho.
///
/// Elas nasceram na direção Presença, que foi substituída pela Mesa. O que
/// ficou aqui é o que as duas superfícies vivas usam — nada mais.
///
/// Mora fora de qualquer `View` pelo motivo de sempre: uma `View` é
/// `@MainActor` implícito e um `static` lá dentro estoura quando um teste
/// `nonisolated` o lê.
enum IAPieceMetrics {

    /// `padding: 8px 14px; font-size: 13px; font-weight: 600` do botão cheio.
    static let primaryPadding = EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
    static let primarySize: CGFloat = 13
    /// `padding: 7px 13px` no secundário com moldura.
    static let secondaryPadding = EdgeInsets(top: 7, leading: 13, bottom: 7, trailing: 13)

    /// Um passo cumprido: `gap: 5px; font-size: 11.5px`, ✓ de 11.
    static let stepItemGap: CGFloat = 5
    static let stepSize: CGFloat = 11.5
    static let stepGlyph: CGFloat = 11
    /// A folga entre os passos do recibo em linha — `gap: 14px`.
    static let receiptGap: CGFloat = 14

    /// O cursor: `width: 10px; height: 22px; border-radius: 2px`.
    static let caretWidth: CGFloat = 10
    static let caretHeight: CGFloat = 22

    /// `shimTxt 1.8s linear infinite`.
    static let shimmer = Animation.linear(duration: 1.8).repeatForever(autoreverses: false)
    /// `caretBlink 1s steps(1) infinite` — meio segundo aceso, meio apagado,
    /// sem rampa (é o que `steps(1)` faz).
    static let caretBlink = Animation.linear(duration: 0.01)
        .delay(0.5).repeatForever(autoreverses: true)
}

/// **O movimento, parado.**
///
/// O desenho respira: o ponto pulsa, o cursor pisca, o fio de tinta corre e as
/// barras do objeto que nasce varrem. Nada disso pode ser comparado em pixels
/// — dois quadros de uma animação nunca são o mesmo quadro —, e o harness de
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
    var size: CGFloat = IAPieceMetrics.stepSize

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
                    .animation(IAPieceMetrics.shimmer, value: phase)
                }
            }
            .onAppear { if !reduceMotion { phase = 1 } }
    }
}


/// Um passo cumprido, com o ✓ do desenho.
struct AssistantStepCheck: View {

    @Environment(\.theme) private var theme

    let text: String
    var size: CGFloat = IAPieceMetrics.stepSize
    var glyph: CGFloat = IAPieceMetrics.stepGlyph

    var body: some View {
        HStack(spacing: IAPieceMetrics.stepItemGap) {
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
        FlowLayout(spacing: IAPieceMetrics.receiptGap, rowSpacing: 4) {
            ForEach(Array(receipt.steps.enumerated()), id: \.offset) { _, passo in
                // `fixedSize`: o passo é curto e tem de aparecer **inteiro**.
                // Sem isto o fluxo achava que os dois cabiam numa linha e
                // cortava o segundo com reticências — um recibo pela metade
                // conta o trabalho pela metade.
                AssistantStepCheck(text: passo).fixedSize()
            }
            if let decorrido = receipt.elapsedLabel {
                Text(decorrido)
                    .font(theme.mono.font(size: IAPieceMetrics.stepSize))
                    .foregroundStyle(theme.ink4.color)
                    .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
