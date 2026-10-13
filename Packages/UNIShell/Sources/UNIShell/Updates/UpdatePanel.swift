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

/// O painel compacto que o ícone abre — e o mesmo que o anúncio "atualizado
/// para X" de Ajustes abre.
///
/// Três casos, um painel: versão pronta, versão recém-instalada e "nada novo".
/// Os dois primeiros têm o mesmo conteúdo pergunta por pergunta — que versão,
/// o que mudou, onde ler o resto — e só o rodapé muda. O terceiro diz a versão
/// em uso e como foi a busca que o clique disparou.
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

    /// Nem pronta nem recém-instalada: o painel é o "você está na última".
    private var semNovidade: Bool { controller.readyVersion == nil }

    var body: some View {
        if semNovidade {
            situacao
        } else {
            novidade
        }
    }

    private var situacao: some View {
        VStack(alignment: .leading, spacing: 11) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.tr("Atualizações"))
                    .font(theme.sans.font(size: 13.5, weight: .semibold))
                    .foregroundStyle(theme.ink.color)
                Text(L10n.tr("Versão \(controller.currentVersion)"))
                    .font(theme.mono.font(size: 11))
                    .foregroundStyle(theme.ink3.color)
            }
            if let mensagem = controller.manualCheckMessage {
                Text(mensagem)
                    .font(theme.sans.font(size: 11.5))
                    .foregroundStyle(theme.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Rectangle()
                .fill(theme.line.color)
                .frame(height: Hairline.thickness(displayScale))
            HStack(spacing: 8) {
                ChromeButton(
                    L10n.tr("Procurar agora"), appearance: .outlined,
                    size: 11.5, height: 27, horizontalPadding: 11
                ) { controller.checkNow() }
                .disabled(controller.isChecking)
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(width: Self.width, alignment: .leading)
        .background(theme.surface.color)
        .accessibilityIdentifier("update-panel")
        .accessibilityElement(children: .contain)
    }

    private var novidade: some View {
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
