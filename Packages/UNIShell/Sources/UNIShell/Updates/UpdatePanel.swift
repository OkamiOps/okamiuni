import SwiftUI
import UNICore
import UNIDesign

/// O botão da lateral: um ícone de download com um ponto de acento.
///
/// Ele só existe em um estado — atualização pronta, no modo de avisar — e é
/// isso que o faz ser lido como notícia em vez de decoração. Um "procurar
/// atualizações" permanente no rodapé seria um botão que na vida real nunca
/// tem nada para dizer; o lugar desse é Ajustes, e ele está lá.
///
/// O ponto é o mesmo recurso que a linha da conta usa para dizer "esta precisa
/// de você" (ver `FolderSidebar.accountRow`): 6pt, cor do acento, sem número.
struct UpdateReadyButton: View {
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
            set: { $0 ? controller.showChangelog() : controller.dismiss() }
        )
    }

    private var rotulo: String {
        guard let version = controller.readyVersion else {
            return L10n.tr("Atualização pronta")
        }
        return L10n.tr("Atualização \(version) pronta para instalar")
    }

    var body: some View {
        HStack(spacing: 0) {
            Button { controller.showChangelog() } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(theme.ink2.color)
                        .accessibilityHidden(true)
                    Circle()
                        .fill(theme.accent.color)
                        .frame(width: Self.dotSize, height: Self.dotSize)
                        .offset(x: 1, y: -1)
                        .accessibilityHidden(true)
                }
                .frame(width: Self.side, height: Self.side)
                .background(
                    theme.surface3.color,
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
            .help(rotulo)
            .accessibilityLabel(rotulo)
            .accessibilityIdentifier("update-ready-button")
            .popover(isPresented: aberto, arrowEdge: .trailing) {
                UpdatePanel(controller: controller)
            }
            Spacer(minLength: 0)
        }
    }
}

/// O painel compacto que o botão abre — e o mesmo que o anúncio "atualizado
/// para X" de Ajustes abre.
///
/// É um painel só para os dois casos porque o conteúdo é o mesmo pergunta por
/// pergunta: que versão, o que mudou, onde ler o resto. O que muda é o rodapé:
/// uma atualização pronta oferece duas ações, uma já instalada só se fecha.
struct UpdatePanel: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.openURL) private var openURL
    let controller: UpdateController

    /// A largura do popover. Estreito de propósito: é um recado, não uma
    /// página de release notes — o link leva a essa.
    static let width: CGFloat = 308

    private var jaInstalada: Bool {
        if case .justUpdated = controller.state { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            cabecalho
            if !controller.changelogBullets.isEmpty {
                mudancas
            }
            if let url = controller.releaseURL {
                linkDoRelease(url)
            }
            Rectangle()
                .fill(theme.line.color)
                .frame(height: Hairline.thickness(displayScale))
            rodape
        }
        .padding(14)
        .frame(width: Self.width, alignment: .leading)
        .background(theme.surface.color)
        .accessibilityIdentifier("update-panel")
        .accessibilityElement(children: .contain)
    }

    private var cabecalho: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(jaInstalada ? L10n.tr("Atualização instalada") : L10n.tr("Atualização pronta"))
                .font(theme.sans.font(size: 13.5, weight: .semibold))
                .foregroundStyle(theme.ink.color)
            if let version = controller.readyVersion {
                Text(L10n.tr("Versão \(version)"))
                    .font(theme.mono.font(size: 11))
                    .foregroundStyle(theme.ink3.color)
            }
        }
    }

    private var mudancas: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr("O que mudou"))
                .capsLabel(size: 8.5)
            // Marcadores desenhados como linhas de texto, e não `Text` com um
            // "•" embutido: o recuo da segunda linha de um item longo tem de
            // alinhar com a primeira palavra, não com o marcador.
            ForEach(Array(controller.changelogBullets.enumerated()), id: \.offset) { _, bullet in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("•")
                        .font(theme.sans.font(size: 11.5))
                        .foregroundStyle(theme.ink4.color)
                        .accessibilityHidden(true)
                    Text(bullet)
                        .font(theme.sans.font(size: 11.5))
                        .foregroundStyle(theme.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func linkDoRelease(_ url: URL) -> some View {
        Button { openURL(url) } label: {
            HStack(spacing: 5) {
                Text(L10n.tr("Ver release no GitHub"))
                    .font(theme.sans.font(size: 11, weight: .medium))
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8.5, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(theme.accent.color)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
    }

    @ViewBuilder
    private var rodape: some View {
        if jaInstalada {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                ChromeButton(
                    L10n.tr("Fechar"), appearance: .outlined,
                    size: 11.5, height: 27, horizontalPadding: 11
                ) { controller.dismiss() }
            }
        } else {
            HStack(spacing: 8) {
                ChromeButton(
                    L10n.tr("Instalar e reabrir"), appearance: .accent,
                    size: 11.5, height: 27, horizontalPadding: 11
                ) { controller.installAndRelaunch() }
                ChromeButton(
                    L10n.tr("Ao fechar o app"), appearance: .outlined,
                    size: 11.5, height: 27, horizontalPadding: 11
                ) { controller.installOnQuit() }
                Spacer(minLength: 0)
            }
        }
    }
}
