import AppKit
import SwiftUI
import UNICore
import UNIDesign

/// O balão da atualização — o que o ícone do trilho abre, e o mesmo que o
/// anúncio "atualizado para X" de Ajustes abre.
///
/// ## O desenho
///
/// Protótipo: `ModalSistema.dc.html`, bloco "ATUALIZAÇÃO". Balão de 380
/// nascido no ícone do trilho, **sem véu** — ele é um recado, não uma parada.
/// Dentro: o ícone do app de 40 ao lado de "Versão X pronta" em 16 e a linha
/// "já baixada · você está na Y" em 12,5; a linha de um pixel; "O QUE MUDOU"
/// com os marcadores em 13,5; e as duas ações lado a lado, o primário
/// crescendo e "Ao fechar o app" no tamanho do texto. O link do release fecha
/// o balão, centrado e discreto.
///
/// Três casos, um balão: versão pronta, versão recém-instalada e "nada novo".
/// Os dois primeiros têm o mesmo conteúdo pergunta por pergunta — que versão,
/// o que mudou, onde ler o resto — e só o rodapé muda. O terceiro diz a versão
/// em uso e como foi a busca que o clique disparou.
///
/// **O arredondamento é do macOS.** Este conteúdo mora dentro de um
/// `.popover`, e o balão (canto, seta, sombra) é desenhado pelo sistema: os 16
/// de raio do protótipo não se aplicam a ele sem reimplementar o popover como
/// janela nossa. O que é nosso — largura, recuos, tipos, cores, ordem — bate.
struct UpdatePanel: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.openURL) private var openURL
    let controller: UpdateController

    /// `width: 380px`, do protótipo.
    static let width: CGFloat = Theme.ModalWidth.updatePopover

    /// `padding: 20px`.
    static let padding: CGFloat = 20

    private var jaInstalada: Bool {
        if case .justUpdated = controller.state { return true }
        return false
    }

    /// Nem pronta nem recém-instalada: o balão é o "você está na última".
    private var semNovidade: Bool { controller.readyVersion == nil }

    var body: some View {
        Group {
            if semNovidade {
                situacao
            } else {
                novidade
            }
        }
        .padding(Self.padding)
        .frame(width: Self.width, alignment: .leading)
        .background(theme.modalSheet.color)
        .accessibilityIdentifier("update-panel")
        .accessibilityElement(children: .contain)
    }

    // MARK: - Nada novo

    private var situacao: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                appIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("Você está na última"))
                        .font(theme.sans.font(size: 16, weight: .semibold))
                        .foregroundStyle(theme.ink.color)
                    Text(L10n.tr("Versão \(controller.currentVersion)"))
                        .font(theme.mono.font(size: 12.5))
                        .foregroundStyle(theme.ink3.color)
                }
                Spacer(minLength: 0)
            }
            if let mensagem = controller.manualCheckMessage {
                Text(mensagem)
                    .font(theme.sans.font(size: 13.5))
                    .foregroundStyle(theme.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ModalSecondaryButton(L10n.tr("Procurar agora")) { controller.checkNow() }
                .disabled(controller.isChecking)
        }
    }

    // MARK: - Versão pronta (ou recém-instalada)

    private var novidade: some View {
        VStack(alignment: .leading, spacing: 14) {
            cabecalho
            if !controller.changelogBullets.isEmpty { mudancas }
            acoes
            if let url = controller.releaseURL { linkDoRelease(url) }
        }
    }

    /// O ícone do app de 40, o título em 16 e a linha de estado em 12,5.
    private var cabecalho: some View {
        HStack(spacing: 12) {
            appIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(jaInstalada
                    ? L10n.tr("Versão \(controller.readyVersion ?? "") instalada")
                    : L10n.tr("Versão \(controller.readyVersion ?? "") pronta"))
                    .font(theme.sans.font(size: 16, weight: .semibold))
                    .foregroundStyle(theme.ink.color)
                    .lineLimit(1)
                Text(jaInstalada
                    ? L10n.tr("instalada ao fechar o app")
                    : L10n.tr("já baixada · você está na \(controller.currentVersion)"))
                    .font(theme.sans.font(size: 12.5))
                    .foregroundStyle(theme.ink3.color)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    /// O ícone **do app**, e não um quadrado com a letra O: o protótipo desenha
    /// um marcador porque um HTML não tem como pedir o ícone do bundle. Aqui
    /// temos, e é ele que a pessoa reconhece no Dock.
    private var appIcon: some View {
        Image(nsImage: NSApp?.applicationIconImage ?? NSImage())
            .resizable()
            .frame(width: 40, height: 40)
            .accessibilityHidden(true)
    }

    private var mudancas: some View {
        VStack(alignment: .leading, spacing: 8) {
            ModalEyebrow(text: L10n.tr("O que mudou"), size: 11, tracking: 0.06)
            // Marcadores desenhados como linhas, e não `Text` com um "•"
            // embutido: o recuo da segunda linha de um item longo tem de
            // alinhar com a primeira palavra, não com o marcador.
            ForEach(Array(controller.changelogBullets.enumerated()), id: \.offset) { _, bullet in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Circle()
                        .fill(theme.accentInk.color)
                        .frame(width: 5, height: 5)
                        .offset(y: -1)
                        .accessibilityHidden(true)
                    Text(bullet)
                        .font(theme.sans.font(size: 13.5))
                        .lineSpacing(0.4 * 13.5)
                        .foregroundStyle(theme.ink.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.top, 13)
        .hairline(theme.modalLine, edges: .top)
    }

    @ViewBuilder
    private var acoes: some View {
        if jaInstalada {
            ModalSecondaryButton(L10n.tr("Fechar")) { controller.dismiss() }
        } else {
            HStack(spacing: 10) {
                ModalPrimaryButton(
                    title: L10n.tr("Instalar e reabrir"),
                    horizontalPadding: 11,
                    fills: true,
                    action: { controller.installAndRelaunch() }
                )
                .accessibilityIdentifier("update-install-now")
                Button { controller.installOnQuit() } label: {
                    Text(L10n.tr("Ao fechar o app"))
                        .font(theme.sans.font(size: 14))
                        .foregroundStyle(theme.ink.color)
                        .lineLimit(1)
                        // Ver `ModalPrimaryButton`: rótulo de botão não cede.
                        // Em alemão esta frase é bem mais longa que em
                        // português, e cortada ela deixa de ser uma escolha.
                        .fixedSize()
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .background(
                            theme.modalButton.color,
                            in: RoundedRectangle(
                                cornerRadius: theme.modalButtonRadius, style: .continuous
                            )
                        )
                        .overlay {
                            RoundedRectangle(
                                cornerRadius: theme.modalButtonRadius, style: .continuous
                            )
                            .strokeBorder(
                                theme.modalButtonEdge.color,
                                lineWidth: Hairline.thickness(displayScale)
                            )
                        }
                        .contentShape(RoundedRectangle(cornerRadius: theme.modalButtonRadius))
                }
                .buttonStyle(.plain)
                .focusRing(cornerRadius: theme.modalButtonRadius)
            }
        }
    }

    private func linkDoRelease(_ url: URL) -> some View {
        Button { openURL(url) } label: {
            HStack(spacing: 5) {
                Text(L10n.tr("Ver a release no GitHub"))
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .font(theme.sans.font(size: 12.5))
            .foregroundStyle(theme.ink3.color)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.modalButtonRadius)
    }
}
