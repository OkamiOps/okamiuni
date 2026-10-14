import SwiftUI
import UNICore
import UNIDesign

/// O ícone de atualização do rodapé da lateral. Fica sempre ali.
///
/// Sempre, e não só com versão pronta: é o lugar onde a pessoa olha para
/// saber "estou na última?", e mandá-la a Ajustes para isso é esconder a
/// resposta. O que vira notícia é o ponto de acento — 6pt, sem número, o mesmo
/// recurso que a linha da conta usa para "esta precisa de você" (ver
/// `FolderSidebar.accountRow`) — e ele só acende com versão pronta no modo de
/// avisar.
struct UpdateButton: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    let controller: UpdateController

    /// O alvo do clique. 30pt é o mesmo quadrado dos botões de ícone do
    /// cabeçalho das janelas auxiliares — não é um tamanho novo.
    static let side: CGFloat = 30
    static let dotSize: CGFloat = 6

    private var aberto: Binding<Bool> {
        Binding(
            get: { controller.isShowingChangelog },
            set: { $0 ? controller.openPanel() : controller.dismiss() }
        )
    }

    private var pronta: Bool { controller.showsReadyButton }

    private var rotulo: String {
        if pronta, let version = controller.readyVersion {
            return L10n.tr("Atualização \(version) pronta para instalar")
        }
        return L10n.tr("Procurar atualizações…")
    }

    var body: some View {
        Button { controller.openPanel() } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle((pronta ? theme.ink2 : theme.ink3).color)
                    .frame(width: Self.side, height: Self.side)
                    .accessibilityHidden(true)
                if pronta {
                    Circle()
                        .fill(theme.accent.color)
                        .frame(width: Self.dotSize, height: Self.dotSize)
                        .offset(x: -6, y: 6)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: Self.side, height: Self.side)
            .background {
                if pronta {
                    RoundedRectangle(cornerRadius: theme.radiusSmall)
                        .fill(theme.surface3.color)
                }
            }
            .overlay {
                if pronta {
                    RoundedRectangle(cornerRadius: theme.radiusSmall)
                        .strokeBorder(
                            theme.accentLine.color,
                            lineWidth: Hairline.thickness(displayScale)
                        )
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
        .help(rotulo)
        .accessibilityLabel(rotulo)
        .accessibilityIdentifier("update-button")
        .popover(isPresented: aberto, arrowEdge: .trailing) {
            UpdatePanel(controller: controller)
        }
    }
}

/// A faixa da versão pronta, no rodapé da lateral.
///
/// Um ponto sobre um ícone não basta para dizer "clique aqui para atualizar":
/// com versão pronta o ícone dá lugar a uma faixa com o número da versão e a
/// palavra "Instalar", que é a ação que a pessoa vai querer. O clique abre o
/// mesmo painel do ícone, com o que mudou e "Instalar e reabrir".
struct UpdateReadyRow: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    let controller: UpdateController

    private var aberto: Binding<Bool> {
        Binding(
            get: { controller.isShowingChangelog },
            set: { $0 ? controller.openPanel() : controller.dismiss() }
        )
    }

    var body: some View {
        let version = controller.readyVersion ?? ""
        Button { controller.openPanel() } label: {
            HStack(spacing: 9) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.accent.color)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                // Duas linhas, como o cartão da IA logo acima: numa linha só,
                // a largura da barra cortava justamente o número da versão.
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.tr("Nova versão"))
                        .font(theme.sans.font(size: 12.5, weight: .semibold))
                        .foregroundStyle(theme.ink.color)
                        .lineLimit(1)
                    Text(L10n.tr("Versão \(version)"))
                        .font(theme.mono.font(size: 10))
                        .foregroundStyle(theme.ink3.color)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(L10n.tr("Instalar"))
                    .font(theme.sans.font(size: 11.5, weight: .semibold))
                    .foregroundStyle(theme.onAccent.color)
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .background(
                        theme.accent.color,
                        in: RoundedRectangle(cornerRadius: theme.radiusSmall)
                    )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(
                theme.accentSoft.color,
                in: RoundedRectangle(cornerRadius: theme.radiusSmall)
            )
            .overlay {
                RoundedRectangle(cornerRadius: theme.radiusSmall)
                    .strokeBorder(
                        theme.accentLine.color,
                        lineWidth: Hairline.thickness(displayScale)
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
        .help(L10n.tr("Atualização \(version) pronta para instalar"))
        .accessibilityLabel(L10n.tr("Atualização \(version) pronta para instalar"))
        .accessibilityIdentifier("update-ready-row")
        .popover(isPresented: aberto, arrowEdge: .trailing) {
            UpdatePanel(controller: controller)
        }
    }
}

