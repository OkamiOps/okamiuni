import SwiftUI
import UNICore
#if canImport(AppKit)
import AppKit
#endif

/// Afere, no app de verdade, se os **botões do sistema** e o cabeçalho custom
/// de cada janela caem na mesma linha.
///
/// ## Por que existe
///
/// A M3-21 declarou as seis janelas alinhadas medindo **bitmap do conteúdo** —
/// e o dono continuou vendo o desencontro na janela de resposta e na de
/// compromisso. A explicação é a própria medida: os semáforos são views do
/// AppKit no `NSThemeFrame`, **fora** do desenho do conteúdo. A foto do
/// `contentView` mostra a barra e um buraco onde eles estão; comparar a barra
/// com um buraco sempre dá alinhado.
///
/// Este ensaio pergunta às molduras de verdade — `standardWindowButton` — e à
/// posição real da barra na janela, e imprime a diferença. `--ensaiar-semaforos`
/// liga; o ensaio abre as janelas pelo mesmo `openWindow` do menu, mede, diz se
/// passou e encerra o app sozinho. Nenhum evento é sintetizado: ele não toca
/// mouse nem teclado.
public struct TrafficLightRehearsal: Sendable {
    public static func parse(_ arguments: [String]) -> TrafficLightRehearsal? {
        arguments.contains("--ensaiar-semaforos") ? TrafficLightRehearsal() : nil
    }

    public static var fromProcess: TrafficLightRehearsal? {
        parse(Array(CommandLine.arguments.dropFirst()))
    }
}

extension View {
    public func rehearseTrafficLightsIfRequested(
        _ request: TrafficLightRehearsal?, store: MailStore
    ) -> some View {
        modifier(TrafficLightRehearsalModifier(request: request, store: store))
    }
}

private struct TrafficLightRehearsalModifier: ViewModifier {
    let request: TrafficLightRehearsal?
    let store: MailStore
    @Environment(\.openWindow) private var openWindow
    @State private var started = false

    func body(content: Content) -> some View {
        content.task {
            guard request != nil, !started else { return }
            started = true
            await run()
        }
    }

    @MainActor
    private func run() async {
        // A janela principal precisa existir antes de qualquer medida, e a
        // agenda precisa estar no store para a 04 abrir num compromisso de
        // verdade em vez de na frase de "não está mais na agenda".
        if store.agenda.isEmpty { await store.load() }
        await espera(1.4)

        // As seis janelas do app. A 03 (responder) e a 04 (compromisso) são as
        // que o dono apontou; as outras vêm junto porque medir uma de cada vez
        // foi como a M3-21 deixou cinco passarem.
        let mensagem = store.messages.first?.id ?? "m1"
        openWindow(id: UNIWindow.composer, value: mensagem)
        openWindow(id: UNIWindow.newMessage, value: "")
        openWindow(id: UNIWindow.message, value: mensagem)
        openWindow(id: UNIWindow.event, value: store.agenda.first?.id ?? "")
        openWindow(id: UNIWindow.accounts)
        await espera(1.8)

        var falhas = 0
        var lidas = 0
        for janela in NSApp.windows where janela.isVisible {
            guard let leitura = TrafficLightAudit.ler(janela, nome: nome(de: janela))
            else { continue }
            lidas += 1
            let passou = abs(leitura.diferenca) <= TrafficLightAudit.tolerancia
            if !passou { falhas += 1 }
            RehearsalStage.log(
                "semáforos — \(leitura.descricao) — "
                + (passou ? "NA LINHA" : "FORA DA LINHA")
            )
        }
        RehearsalStage.log(
            lidas == 0
                ? "semáforos: NENHUMA JANELA MEDIDA — o ensaio não prova nada"
                : "semáforos: \(lidas) janelas medidas, \(falhas) fora da linha — "
                    + (falhas == 0 && lidas >= 6 ? "VERIFICADO" : "FALHOU")
        )
        NSApp.terminate(nil)
    }

    /// O nome pelo qual o relatório chama cada janela. O identificador da cena
    /// vem no `identifier` que o SwiftUI carimba (`uni.composer-AppWindow-1`).
    private func nome(de janela: NSWindow) -> String {
        let id = janela.identifier?.rawValue ?? ""
        for (cena, rótulo) in [
            (UNIWindow.composer, "03 responder"),
            (UNIWindow.newMessage, "06 nova mensagem"),
            (UNIWindow.message, "05 email"),
            (UNIWindow.event, "04 compromisso"),
            (UNIWindow.accounts, "Configurações"),
        ] where id.hasPrefix(cena) {
            return rótulo
        }
        return "principal"
    }

    private func espera(_ segundos: Double) async {
        try? await Task.sleep(for: .seconds(segundos))
    }
}
