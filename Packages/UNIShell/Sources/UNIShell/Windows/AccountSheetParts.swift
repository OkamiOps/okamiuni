import SwiftUI
import UNICore
import UNIDesign
import UNISync

// As peças que as duas folhas de conta compartilham — os três passos do
// caminho e a trilha do teste IMAP.

/// O caminho inteiro, à vista: três passos numerados com a linha que os liga.
///
/// Protótipo (`ModalContas.dc.html`): grade de três colunas, círculo de 28 com
/// borda de 2, a linha de 2px em `top: 17px`, rótulo de 11,5 centrado. O passo
/// cumprido vira `✓` em verde, o atual é o acento cheio, o que falta é oco com
/// a borda em `stepTodo`.
///
/// Existe porque a queixa é velha: "autorizar no Google" abria o navegador e a
/// pessoa não sabia quantos passos faltavam nem o que ia acontecer quando
/// voltasse. Três círculos resolvem isso antes do primeiro clique.
struct AccountPathSteps: View {
    @Environment(\.theme) private var theme

    enum State: Equatable {
        case done
        case now
        case waiting
    }

    struct Step: Identifiable, Equatable {
        let id: Int
        let label: String
        let state: State
    }

    let steps: [Step]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                stepView(step, isLast: index == steps.count - 1)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            steps.first { $0.state == .now }.map { L10n.tr("Passo \($0.id) de \(steps.count): \($0.label)") }
                ?? L10n.tr("Caminho da conta")
        )
    }

    private func stepView(_ step: Step, isLast: Bool) -> some View {
        VStack(spacing: 8) {
            ZStack(alignment: .top) {
                // A linha sai do centro do círculo deste passo para o do
                // seguinte: `top: 17px; left: 50%; width: 100%` no protótipo.
                if !isLast {
                    GeometryReader { proxy in
                        Rectangle()
                            .fill((step.state == .done ? theme.modalGreen : theme.modalFieldEdge).color)
                            .frame(width: proxy.size.width, height: 2)
                            .offset(x: proxy.size.width / 2, y: 13)
                    }
                    .frame(height: 28)
                    .accessibilityHidden(true)
                }
                mark(step)
            }
            Text(step.label)
                .font(theme.sans.font(size: 11.5, weight: step.state == .now ? .semibold : .medium))
                .foregroundStyle((step.state == .waiting ? theme.ink3 : theme.ink).color)
                .multilineTextAlignment(.center)
                .lineSpacing(0.3 * 11.5)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
    }

    @ViewBuilder
    private func mark(_ step: Step) -> some View {
        let fill: Color = switch step.state {
        case .done: theme.modalGreen.color
        case .now: theme.accent.color
        case .waiting: theme.modalSheet.color
        }
        let ink: Color = switch step.state {
        case .done: theme.modalSheet.color
        case .now: theme.onAccent.color
        case .waiting: theme.ink3.color
        }
        Group {
            if step.state == .done {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
            } else {
                Text("\(step.id)")
                    .font(theme.mono.font(size: 12, weight: .semibold))
            }
        }
        .foregroundStyle(ink)
        .frame(width: 28, height: 28)
        .background(fill, in: Circle())
        .overlay {
            Circle().strokeBorder(
                step.state == .waiting ? theme.modalFieldEdge.color : .clear, lineWidth: 2
            )
        }
    }
}

/// O que o teste de IMAP faz, passo a passo, **dentro** da folha.
///
/// ## O que é honesto afirmar aqui
///
/// `AccountDirector.testImap` é uma chamada só: abre a conexão, faz `LOGIN`,
/// faz `LOGOUT`. Ela não publica progresso, e por isso esta trilha **não
/// inventa** um cronômetro por etapa como o protótipo desenha. O que ela faz é
/// o que o resultado permite dizer com certeza:
///
/// - antes de começar, os quatro passos esperam;
/// - enquanto roda, o primeiro está em curso e o resto espera;
/// - passou: os quatro cumpridos — porque passar é, literalmente, ter passado
///   por todos;
/// - falhou: a **classe do erro** diz onde parou. `.rede` é não ter chegado ao
///   servidor; `.tls` é ter chegado e não ter fechado o canal; `.autenticacao`
///   e `.autorizacaoRevogada` são ter fechado o canal e a senha ter sido
///   recusada — ou seja, os dois primeiros passaram.
///
/// Os tempos ("0,3 s") do desenho ficaram de fora: medir cada etapa exige
/// quebrar o `testImap` em três chamadas observáveis, que é mudança de
/// `UNISync` e não de desenho. Está no relatório como não reproduzido.
enum ImapTestTrail {
    struct Step: Identifiable, Equatable {
        let id: Int
        let label: String
        let state: AccountPathSteps.State
        /// `true` quando é **neste** passo que o erro apareceu.
        var failed = false
    }

    static func labels() -> [String] {
        [
            L10n.tr("Servidor encontrado"),
            L10n.tr("Conexão segura (TLS)"),
            L10n.tr("Entrando com a senha de app…"),
            L10n.tr("Listando as pastas"),
        ]
    }

    /// `running` manda na frente; `error` decide onde a trilha para.
    static func steps(running: Bool, passed: Bool?, error: SyncError?) -> [Step] {
        let labels = labels()
        if let error {
            let parou = failureIndex(error)
            return labels.enumerated().map { index, label in
                Step(
                    id: index + 1, label: label,
                    state: index < parou ? .done : (index == parou ? .now : .waiting),
                    failed: index == parou
                )
            }
        }
        if passed == true {
            return labels.enumerated().map {
                Step(id: $0.offset + 1, label: $0.element, state: .done)
            }
        }
        if running {
            return labels.enumerated().map {
                Step(id: $0.offset + 1, label: $0.element, state: $0.offset == 0 ? .now : .waiting)
            }
        }
        return labels.enumerated().map {
            Step(id: $0.offset + 1, label: $0.element, state: .waiting)
        }
    }

    /// Em que passo (base zero) a classe do erro põe a falha.
    static func failureIndex(_ error: SyncError) -> Int {
        switch error {
        case .rede, .transitorio: 0
        case .tls: 1
        case .autenticacao, .autorizacaoRevogada, .recusado: 2
        default: 3
        }
    }
}

/// A trilha desenhada: `background: soft; border-radius: 12; padding: 13px 16px`,
/// com `gap: 9px` e cada linha em 13,5.
struct ImapTestTrailView: View {
    @Environment(\.theme) private var theme
    let steps: [ImapTestTrail.Step]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(steps) { step in
                HStack(spacing: 10) {
                    icon(step)
                    Text(step.label)
                        .font(theme.sans.font(size: 13.5))
                        .foregroundStyle(tint(step).color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            theme.modalSoft.color,
            in: RoundedRectangle(cornerRadius: theme.modalFieldRadius, style: .continuous)
        )
    }

    private func tint(_ step: ImapTestTrail.Step) -> TokenColor {
        if step.failed { return theme.modalRed }
        return step.state == .waiting ? theme.ink3 : theme.ink
    }

    @ViewBuilder
    private func icon(_ step: ImapTestTrail.Step) -> some View {
        Group {
            if step.failed {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.modalRed.color)
            } else if step.state == .done {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.modalGreen.color)
            } else if step.state == .now {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Circle()
                    .fill(theme.ink3.color)
                    .frame(width: 5, height: 5)
            }
        }
        .frame(width: 15, height: 15)
        .accessibilityHidden(true)
    }
}
