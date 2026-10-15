import SwiftUI
import UNICore
import UNIDesign

/// A linha de Atualizações: a versão instalada e "Procurar agora", ou a versão
/// pronta com "Notas" e "Instalar e reabrir".
///
/// Mora na Visão geral, a primeira página das Configurações: é ali que a
/// pessoa procura "estou na última?". Em Aparência ela ficava escondida.
struct ConfigUpdatesRow: View {
    @Environment(\.theme) private var theme
    @Environment(\.configPalette) private var palette
    let updates: UpdateController?

    var body: some View {
        ConfigRow(
            label: L10n.tr("Atualizações"),
            note: L10n.tr("procura sozinha uma vez por dia; instala só quando você mandar"),
            divider: .bottom
        ) {
            HStack(spacing: 12) {
                if let updates {
                    if let ready = updates.readyVersion, updates.showsReadyButton {
                        Text(L10n.tr("\(ready) pronta"))
                            .font(theme.sans.font(size: 13, weight: .medium))
                            .foregroundStyle(palette.accentInk.color)
                        Button(L10n.tr("Notas")) { updates.showChangelog() }
                            .buttonStyle(.plain)
                            .font(theme.sans.font(size: 13))
                            .foregroundStyle(palette.ink3.color)
                        Button(L10n.tr("Instalar e reabrir")) { updates.installAndRelaunch() }
                            .buttonStyle(.plain)
                            .configPrimaryButton(
                                palette, font: theme.sans.font(size: 13, weight: .semibold),
                                radius: 9, horizontal: 13, vertical: 8
                            )
                            .accessibilityIdentifier("settings-install-update")
                    } else {
                        Text(updates.versionLine)
                            .font(theme.mono.font(size: 12))
                            .foregroundStyle(palette.ink3.color)
                        Button(L10n.tr("Procurar agora")) { updates.checkNow() }
                            .buttonStyle(.plain)
                            .configQuietButton(palette, font: theme.sans.font(size: 13, weight: .medium))
                            .disabled(updates.isChecking)
                    }
                } else {
                    // Build de desenvolvimento: o atualizador está desligado de
                    // propósito, e dizer isso é melhor do que oferecer um botão
                    // que não procura nada.
                    Text(L10n.tr("desligadas neste build"))
                        .font(theme.sans.font(size: 13))
                        .foregroundStyle(palette.ink3.color)
                }
            }
        }
    }
}
