import AppKit
import SwiftUI
import UNIDesign
import UNICore
import UniformTypeIdentifiers

/// Onde o app está rodando — e se, de lá, ele consegue se atualizar.
///
/// Quem baixa o `.dmg` às vezes abre o OkamiUNI direto da janela do
/// instalador, sem arrastar para Aplicativos. Funciona, mas o volume é só de
/// leitura e some ao ejetar: o Sparkle não tem onde instalar a versão nova. O
/// mesmo vale para um app em quarentena aberto de Downloads, que o macOS roda
/// de uma cópia translocada e também só de leitura.
public enum AppLocation {

    /// `true` quando o app está num lugar de onde não dá para se atualizar.
    public static func needsMove(bundlePath: String) -> Bool {
        bundlePath.hasPrefix("/Volumes/") || bundlePath.contains("/AppTranslocation/")
    }
}

/// O convite para mover o app para Aplicativos.
///
/// O app roda em sandbox e não pode escrever em `/Applications` por conta
/// própria. Por isso o caminho passa por um painel do sistema: a pessoa
/// confirma o destino, o sandbox libera aquele endereço, o app se copia para
/// lá, abre a cópia e fecha a que estava no instalador.
@MainActor
enum MoveToApplications {

    static func move(_ origem: URL) {
        let painel = NSSavePanel()
        painel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        painel.nameFieldStringValue = origem.lastPathComponent
        painel.allowedContentTypes = [.applicationBundle]
        painel.canCreateDirectories = false
        painel.prompt = L10n.tr("Mover")
        painel.message = L10n.tr("Confirme a pasta Aplicativos para instalar o OkamiUNI.")
        guard painel.runModal() == .OK, let destino = painel.url else { return }

        do {
            let arquivos = FileManager.default
            if arquivos.fileExists(atPath: destino.path) {
                // A versão antiga vai para a Lixeira, e não some: se a cópia
                // falhar no meio, ainda dá para recuperá-la.
                try arquivos.trashItem(at: destino, resultingItemURL: nil)
            }
            try arquivos.copyItem(at: origem, to: destino)
        } catch {
            let falha = NSAlert(error: error)
            falha.informativeText = L10n.tr(
                "Arraste o OkamiUNI para a pasta Aplicativos pela janela do instalador."
            )
            falha.runModal()
            return
        }

        let abertura = NSWorkspace.OpenConfiguration()
        abertura.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: destino, configuration: abertura) { _, erro in
            guard erro == nil else { return }
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}

/// A folha do convite — o primeiro abrir, quando o app está rodando do
/// instalador.
///
/// Protótipo: `ModalSistema.dc.html`, bloco "MOVER PARA APLICATIVOS". 460 de
/// largura, **centrada** (é uma parada, não uma folha do app), `padding: 28px`,
/// e no topo o ícone do app → a flecha → a pasta, que é a frase inteira dita em
/// três desenhos antes de qualquer texto. O título e a explicação vêm
/// centrados embaixo, e as duas ações dividem a largura em colunas iguais.
///
/// A ordem dos botões é a do desenho: "Agora não" à esquerda, "Mover e
/// reabrir" à direita, no acento.
struct MoveToApplicationsSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    var icon: NSImage = NSApp?.applicationIconImage ?? NSImage()
    let onMove: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            jornada
            VStack(spacing: 7) {
                Text(L10n.tr("Mover para Aplicativos?"))
                    .font(theme.sans.font(size: 20, weight: .bold))
                    .tracking(theme.modalTitleTracking(at: 20) * 0.75)
                    .foregroundStyle(theme.ink.color)
                Text(L10n.tr("De lá o OkamiUNI atualiza sozinho e o macOS guarda as permissões de Calendários e notificações."))
                    .font(theme.sans.font(size: 14))
                    .lineSpacing(0.5 * 14)
                    .foregroundStyle(theme.ink3.color)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                ModalSecondaryButton(L10n.tr("Agora não")) { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                ModalPrimaryButton(
                    title: L10n.tr("Mover e reabrir"), horizontalPadding: 0,
                    fills: true, action: onMove
                )
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("move-to-applications")
            }
            .padding(.top, 2)
        }
        .padding(28)
        .frame(width: Theme.ModalWidth.smallSheet)
        .modalSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("Mover para Aplicativos?"))
    }

    /// Daqui para lá: o ícone do app, a flecha, a pasta. Dois quadrados de 56
    /// com a flecha de 26 entre eles.
    private var jornada: some View {
        HStack(spacing: 18) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 56, height: 56)
            Image(systemName: "arrow.right")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(theme.ink3.color)
            Image(systemName: "folder")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(theme.accentInk.color)
                .frame(width: 56, height: 56)
                .background(
                    theme.modalSoft.color,
                    in: RoundedRectangle(cornerRadius: theme.modalFieldRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: theme.modalFieldRadius, style: .continuous)
                        .strokeBorder(
                            theme.modalLine.color, lineWidth: Hairline.thickness(displayScale)
                        )
                }
        }
        .padding(.top, 8)
        .padding(.bottom, 2)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Na abertura, se o app estiver rodando do instalador (ou translocado),
    /// oferece mover para Aplicativos. `enabled` é falso em Debug: um build de
    /// desenvolvimento não tem atualizador e roda de onde o Xcode o pôs.
    public func offeringMoveToApplications(enabled: Bool, bundle: Bundle = .main) -> some View {
        modifier(MoveToApplicationsOffer(enabled: enabled, bundle: bundle))
    }
}

private struct MoveToApplicationsOffer: ViewModifier {
    let enabled: Bool
    let bundle: Bundle
    @State private var aberto = false

    func body(content: Content) -> some View {
        content
            .task {
                aberto = enabled && AppLocation.needsMove(bundlePath: bundle.bundlePath)
            }
            // Centrado, e não `.sheet`: é o primeiro abrir do app, uma
            // parada antes de qualquer coisa — ver `CenteredModal`.
            .centeredModal(isPresented: aberto, onDismiss: { aberto = false }) {
                MoveToApplicationsSheet(
                    onMove: {
                        aberto = false
                        MoveToApplications.move(bundle.bundleURL)
                    },
                    onDismiss: { aberto = false }
                )
            }
    }
}
