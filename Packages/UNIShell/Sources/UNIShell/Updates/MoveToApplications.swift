import AppKit
import SwiftUI
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

/// A folha do convite, no visual do app.
struct MoveToApplicationsSheet: View {
    @Environment(\.theme) private var theme
    var icon: NSImage = NSApp?.applicationIconImage ?? NSImage()
    let onMove: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("Mover o OkamiUNI para Aplicativos?"))
                        .font(theme.sans.font(size: 14, weight: .semibold))
                        .foregroundStyle(theme.ink.color)
                    Text(L10n.tr(
                        "O app está aberto de dentro do instalador. Na pasta Aplicativos ele recebe as atualizações sozinho."
                    ))
                    .font(theme.sans.font(size: 12))
                    .foregroundStyle(theme.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                ChromeButton(
                    L10n.tr("Agora não"), appearance: .outlined,
                    size: 12, height: 28, horizontalPadding: 12
                ) { onDismiss() }
                .keyboardShortcut(.cancelAction)
                ChromeButton(
                    L10n.tr("Mover para Aplicativos"), appearance: .accent,
                    size: 12, height: 28, horizontalPadding: 12
                ) { onMove() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("move-to-applications")
            }
        }
        .padding(20)
        .frame(width: 420, alignment: .leading)
        .background(theme.surface.color)
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
            .sheet(isPresented: $aberto) {
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
