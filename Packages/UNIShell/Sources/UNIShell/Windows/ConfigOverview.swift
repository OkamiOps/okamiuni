import SwiftUI
import UNICore
import UNIDesign
import UNISync

/// Um problema que pede um minuto da pessoa. **Uma** ação cada: o desenho é
/// explícito nisso, e é o que separa esta página de um painel de estado.
struct ConfigAlert: Identifiable {
    enum Tone { case needsYou, whenever }

    let id: String
    let tone: Tone
    let symbol: String
    let tag: String
    let title: String
    let detail: String
    let action: String
    /// Um segundo caminho que **não** age sobre nada — as notas da versão, por
    /// exemplo. Fica como link, nunca como botão.
    var link: (label: String, run: () -> Void)?
    let run: () -> Void
}

/// "Tudo em ordem?": os problemas primeiro, o resto em azulejos clicáveis.
struct ConfigOverview: View {
    @Environment(\.theme) private var theme
    @Environment(\.configPalette) private var palette

    let alerts: [ConfigAlert]
    let tiles: [ConfigOverviewTile]
    let checkedNote: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(alerts) { alertCard($0) }

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(alerts.isEmpty
                         ? L10n.tr("Está tudo em ordem")
                         : L10n.tr("O resto está em ordem"))
                        .font(theme.sans.font(size: 16, weight: .semibold))
                        .tracking(-0.01 * 16)
                        .foregroundStyle(palette.ink.color)
                    Text(checkedNote)
                        .font(theme.sans.font(size: 13))
                        .foregroundStyle(palette.ink3.color)
                    Spacer(minLength: 0)
                }
                .padding(.top, 14)
                .padding(.horizontal, 2)
                .padding(.bottom, 2)

                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(tiles) { ConfigOverviewTileView(tile: $0) }
                }

                Text(L10n.tr("Senhas e chaves ficam no Keychain deste Mac. Nada daqui sobe para servidor nenhum."))
                    .font(theme.sans.font(size: 12.5))
                    .foregroundStyle(palette.ink3.color)
                    .padding(.top, 8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: ConfigMetrics.contentMaxWidth, alignment: .leading)
            .padding(.bottom, 4)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    /// `grid-template-columns: 46px minmax(0,1fr) auto; gap: 16px;
    /// padding: 16px 18px; border-radius: 16px`.
    private func alertCard(_ alert: ConfigAlert) -> some View {
        let accentTone = alert.tone == .needsYou ? palette.orange : palette.accentInk
        return HStack(spacing: 16) {
            Image(systemName: alert.symbol)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(accentTone.color)
                .frame(width: 46, height: 46)
                .background(accentTone.color.opacity(0.13), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(alert.tag)
                    .font(theme.sans.font(size: 11.5, weight: .bold))
                    .tracking(0.06 * 11.5)
                    .foregroundStyle(accentTone.color)
                Text(alert.title)
                    .font(theme.sans.font(size: 16.5, weight: .semibold))
                    .tracking(-0.01 * 16.5)
                    .foregroundStyle(palette.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
                Text(alert.detail)
                    .font(theme.sans.font(size: 13))
                    .foregroundStyle(palette.ink3.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)

            HStack(spacing: 16) {
                if let link = alert.link {
                    Button(link.label, action: link.run)
                        .buttonStyle(.plain)
                        .font(theme.sans.font(size: 13))
                        .foregroundStyle(palette.ink3.color)
                }
                Button(alert.action, action: alert.run)
                    .buttonStyle(.plain)
                    .modifier(AlertActionStyle(palette: palette, strong: alert.tone == .needsYou))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .configCard(palette)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(alert.title)
    }
}

private struct AlertActionStyle: ViewModifier {
    @Environment(\.theme) private var theme
    let palette: ConfigPalette
    let strong: Bool

    func body(content: Content) -> some View {
        if strong {
            content.configPrimaryButton(palette, font: theme.sans.font(size: 13, weight: .semibold))
        } else {
            content.configQuietButton(
                palette, font: theme.sans.font(size: 13, weight: .semibold),
                radius: 10, horizontal: 16, vertical: 10
            )
        }
    }
}

/// Um azulejo da visão geral: a área, o fato grande, a explicação — e um
/// destino. Ele é um atalho, não um relatório.
struct ConfigOverviewTile: Identifiable {
    enum Ornament {
        case none
        /// A amostra do tema em uso: `width: 42px; height: 30px`.
        case swatch(AnyView)
        /// Os avatares sobrepostos das contas.
        case faces([(initial: String, tint: Color)])
    }

    let id: String
    let area: String
    let symbol: String
    let tint: TokenColor
    let headline: String
    let detail: String
    var ornament: Ornament = .none
    let open: () -> Void
}

struct ConfigOverviewTileView: View {
    @Environment(\.theme) private var theme
    @Environment(\.configPalette) private var palette
    @Environment(\.displayScale) private var displayScale
    let tile: ConfigOverviewTile

    var body: some View {
        Button(action: tile.open) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: tile.symbol)
                        .font(.system(size: 12, weight: .semibold))
                    Text(tile.area)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(palette.ink3.color)
                }
                .font(theme.sans.font(size: 12.5, weight: .semibold))
                .foregroundStyle(tile.tint.color)

                HStack(spacing: 12) {
                    ornament
                    Text(tile.headline)
                        .font(theme.sans.font(size: 18, weight: .semibold))
                        .tracking(-0.015 * 18)
                        .foregroundStyle(palette.ink.color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                }

                Text(tile.detail)
                    .font(theme.sans.font(size: 12.5))
                    .foregroundStyle(palette.ink3.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .configTile(palette)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: 14)
        .accessibilityLabel("\(tile.area): \(tile.headline)")
        .accessibilityHint(tile.detail)
    }

    @ViewBuilder
    private var ornament: some View {
        switch tile.ornament {
        case .none:
            EmptyView()
        case .swatch(let view):
            view
                .frame(width: 42, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(palette.line.color, lineWidth: Hairline.thickness(displayScale))
                }
        case .faces(let faces):
            HStack(spacing: -6) {
                ForEach(Array(faces.enumerated()), id: \.offset) { _, face in
                    Text(face.initial)
                        .font(theme.sans.font(size: 11, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(width: 26, height: 26)
                        .background(face.tint, in: Circle())
                        .overlay { Circle().strokeBorder(palette.ring.color, lineWidth: 2) }
                }
            }
        }
    }
}
