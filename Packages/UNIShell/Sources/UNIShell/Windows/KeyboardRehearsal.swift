import SwiftUI
import UNICore
#if canImport(AppKit)
import AppKit
#endif

/// Ensaia os **atalhos de teclado** dentro do app de verdade.
///
/// ## Por que existe
///
/// "os atalhos do teclado nao funciona" — o dono do projeto, sobre `a8bff0e`.
/// Havia `.keyboardShortcut` escrito em quatro lugares e um menu de contexto que
/// prometia navegação por setas; nada disso é prova de que a tecla chega.
/// A prova é esta: a tecla é sintetizada dentro do processo, posta na fila do
/// próprio app (`NSApp.postEvent`) e o ensaio afere o **efeito** — a janela que
/// abriu, o realce que andou, o envio que registrou no stderr.
///
/// `--ensaiar-teclado` liga; sem a bandeira, nada acontece. Nenhum evento é
/// postado no sistema: o mouse e o teclado da máquina não são tocados.
public struct KeyboardRehearsal: Sendable {
    public static func parse(_ arguments: [String]) -> KeyboardRehearsal? {
        arguments.contains("--ensaiar-teclado") ? KeyboardRehearsal() : nil
    }

    public static var fromProcess: KeyboardRehearsal? {
        parse(Array(CommandLine.arguments.dropFirst()))
    }
}

extension View {
    public func rehearseKeyboardIfRequested(
        _ request: KeyboardRehearsal?, store: MailStore
    ) -> some View {
        modifier(KeyboardRehearsalModifier(request: request, store: store))
    }
}

private struct KeyboardRehearsalModifier: ViewModifier {
    let request: KeyboardRehearsal?
    let store: MailStore
    @State private var started = false

    func body(content: Content) -> some View {
        content.background(
            KeyboardProbe(request: request, store: store, started: $started)
                .frame(width: 0, height: 0)
        )
    }
}

private struct KeyboardProbe: NSViewRepresentable {
    let request: KeyboardRehearsal?
    let store: MailStore
    @Binding var started: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        guard request != nil, !started else { return }
        started = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            guard let window = view.window else {
                RehearsalStage.log("teclado: sem janela"); NSApp.terminate(nil); return
            }
            await KeyboardDriver(window: window, store: store).run()
            NSApp.terminate(nil)
        }
    }
}

@MainActor
private final class KeyboardDriver {
    let driver: RehearsalDriver
    let store: MailStore
    var window: NSWindow { driver.window }

    init(window: NSWindow, store: MailStore) {
        self.driver = RehearsalDriver(window: window)
        self.store = store
    }

    func run() async {
        // A janela precisa ser a chave do app ativo: é a janela-chave que
        // recebe `performKeyEquivalent` de `NSApplication.sendEvent`.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        await settle()
        RehearsalStage.log("partida — \(RehearsalWindows.census())")
        RehearsalStage.log(
            "seleção natural: \(store.selectedMessageID ?? "nenhuma") · "
            + "respondedor: \(responder())"
        )

        await cmdR(rótulo: "⌘R no estado natural")
        await cmdN()
        await cmdReturnNaFaixa()
        await cmdReturnNoComposer()
        await cmdK()
        await teclaEmCampoDeTexto()
        await cmdR(rótulo: "⌘R com o foco na busca")
        await menuDeContexto()
    }

    // MARK: - ⌘R

    /// Responder com a mensagem selecionada. O efeito aferível é a janela 03:
    /// `uni.composer`, e não outra cena qualquer.
    private func cmdR(rótulo: String) async {
        await focar()
        let antes = RehearsalWindows.visible().count
        driver.send(key: RehearsalKey.r, characters: "r", modifiers: .command)
        await settle(0.8)
        let abertas = RehearsalWindows.visible()
        let composer = abertas.contains { $0.identifier?.rawValue.hasPrefix(UNIWindow.composer) == true }
        RehearsalStage.log(
            "\(rótulo) [\(estado)]: janelas \(antes) → \(abertas.count), uni.composer=\(composer) — "
            + "\(composer ? "ABRIU" : "MORTO")"
        )
        await closeExtras(keeping: antes)
    }

    // MARK: - ⌘N

    private func cmdN() async {
        await focar()
        let antes = RehearsalWindows.visible().count
        driver.send(key: RehearsalKey.n, characters: "n", modifiers: .command)
        await settle(0.8)
        let abertas = RehearsalWindows.visible()
        let nova = abertas.contains { $0.identifier?.rawValue.hasPrefix(UNIWindow.newMessage) == true }
        RehearsalStage.log(
            "⌘N [\(estado)]: janelas \(antes) → \(abertas.count), uni.newMessage=\(nova) — "
            + "\(nova ? "ABRIU" : "MORTO")"
        )
        await closeExtras(keeping: antes)
    }

    // MARK: - ⌘⏎ na faixa de resposta

    /// A faixa da mensagem selecionada tem destinatário e texto semeados, então
    /// o "Enviar" está aceso. Enviar carimba o rascunho — é isso que se afere,
    /// e não a rede, que não existe neste marco.
    private func cmdReturnNaFaixa() async {
        await focar()
        guard let id = store.selectedMessageID else {
            RehearsalStage.log("⌘⏎ na faixa: sem mensagem selecionada, não pôde ser ensaiado")
            return
        }
        let antes = store.replyDraft(for: id)?.sentAt
        driver.send(key: RehearsalKey.ret, characters: "\r", modifiers: .command)
        await settle(0.8)
        let depois = store.replyDraft(for: id)?.sentAt
        RehearsalStage.log(
            "⌘⏎ na faixa [\(estado)]: carimbo \(antes.map(String.init(describing:)) ?? "nenhum") → "
            + "\(depois.map(String.init(describing:)) ?? "nenhum") — "
            + "\(depois != nil && antes == nil ? "ENVIOU" : "MORTO")"
        )
    }

    // MARK: - ⌘⏎ na janela 03

    /// O rodapé do composer também escreve "⌘⏎" ao lado de "Enviar". A prova é
    /// a janela fechar: `ComposerWindow.send` registra no stderr e chama
    /// `dismiss()`.
    private func cmdReturnNoComposer() async {
        await focar()
        let base = RehearsalWindows.visible().count
        driver.send(key: RehearsalKey.r, characters: "r", modifiers: .command)
        await settle(0.9)
        guard let composer = RehearsalWindows.visible().first(
            where: { $0.identifier?.rawValue.hasPrefix(UNIWindow.composer) == true }
        ) else {
            RehearsalStage.log("⌘⏎ no composer: a janela 03 não abriu, ensaio impossível")
            return
        }
        composer.makeKeyAndOrderFront(nil)
        await settle(0.5)
        RehearsalDriver(window: composer)
            .send(key: RehearsalKey.ret, characters: "\r", modifiers: .command)
        await settle(0.9)
        let restou = RehearsalWindows.visible().count
        RehearsalStage.log(
            "⌘⏎ no composer: janelas \(base + 1) → \(restou) — "
            + "\(restou == base ? "ENVIOU e fechou" : "MORTO")"
        )
        await closeExtras(keeping: base)
    }

    // MARK: - ⌘K

    /// O campo de busca **escreve "⌘K" dentro de si**. Ou o app escuta, ou o
    /// campo está mentindo — é a mesma regra do botão mudo, aplicada ao atalho.
    private func cmdK() async {
        await focar()
        window.makeFirstResponder(nil)
        await settle(0.3)
        let antes = responder()
        driver.send(key: RehearsalKey.k, characters: "k", modifiers: .command)
        await settle(0.7)
        let depois = responder()
        RehearsalStage.log(
            "⌘K [\(estado)]: respondedor \(antes) → \(depois) — "
            + "\(depois.contains("FieldEditor") ? "FOCOU a busca" : "MORTO")"
        )
    }

    // MARK: - O atalho não pode roubar tecla de campo de texto

    /// Digitar "r" na busca tem de escrever "r" na busca — e não responder.
    private func teclaEmCampoDeTexto() async {
        await focar()
        // O campo de busca fica na barra do topo, na linha média dos controles.
        driver.click(at: driver.point(x: 480, fromTop: 22))
        await settle(0.5)
        RehearsalStage.log("busca: respondedor depois do clique — \(responder())")
        let janelas = RehearsalWindows.visible().count
        store.query = ""
        driver.send(key: RehearsalKey.r, characters: "r")
        await settle(0.6)
        RehearsalStage.log(
            "\"r\" na busca: query=\"\(store.query)\" janelas \(janelas) → "
            + "\(RehearsalWindows.visible().count) — "
            + "\(store.query == "r" && RehearsalWindows.visible().count == janelas ? "ESCREVEU, não respondeu" : "DEFEITO")"
        )
        driver.shoot("teclado-busca")
    }

    // MARK: - Menu de contexto

    /// Abre o menu da primeira linha da lista com o botão direito e navega só
    /// por teclado. O ponto é o mesmo que `SwipeRehearsal` usa para pegar a
    /// primeira linha: depois da lateral, sob o cabeçalho da lista.
    ///
    /// A ordem de `ContextMenus.messageRow` é conhecida: 0 "Abrir em janela",
    /// 1 "Responder", 2 traço, 3 estado de leitura, 4 o submenu "Mover para".
    /// É por isso que o ensaio sabe onde ↑ ↓ têm de parar e em que linha → tem
    /// de entrar.
    private func menuDeContexto() async {
        await focar()
        let presenter = ContextMenuPresenter.shared
        driver.rightClick(at: driver.point(x: 300, fromTop: 150))
        await settle(0.7)
        RehearsalStage.log("menu: abriu? \(presenter.isOpen) — \(presenter.rehearsalState)")
        guard presenter.isOpen else {
            RehearsalStage.log("menu: sem painel, navegação não pôde ser ensaiada")
            return
        }

        await tecla(RehearsalKey.down, "\u{F701}", "menu ↓")
        await tecla(RehearsalKey.down, "\u{F701}", "menu ↓↓")
        await tecla(RehearsalKey.up, "\u{F700}", "menu ↑")
        driver.shoot("teclado-menu-realce")

        // → numa linha comum não é ⏎: ela não pode executar nada nem fechar o
        // menu. Este é o passo que pegou o defeito.
        await tecla(RehearsalKey.right, "\u{F703}", "menu → em linha comum")
        RehearsalStage.log(
            "menu: continua aberto depois do →? \(presenter.isOpen) — "
            + "\(presenter.isOpen ? "certo" : "DEFEITO (→ executou e fechou)")"
        )
        guard presenter.isOpen else { return }

        // Desce até o submenu "Mover para" e entra nele. O realce é procurado
        // pelo nome, não contado por índice: a lista muda com o estado da
        // mensagem (arquivada não oferece "Arquivar") e um índice cravado aqui
        // mediria outra linha no primeiro conserto do modelo.
        var achou = false
        for _ in 0..<10 where !achou {
            driver.send(key: RehearsalKey.down, characters: "\u{F701}")
            await settle(0.25)
            achou = presenter.rehearsalState.contains("Mover para")
        }
        guard achou else {
            RehearsalStage.log("menu: submenu “Mover para” não foi alcançado pelas setas")
            return
        }
        RehearsalStage.log("menu ↓ até o submenu: \(presenter.rehearsalState)")

        await tecla(RehearsalKey.right, "\u{F703}", "menu → no submenu")
        RehearsalStage.log(
            "menu →: \(presenter.rehearsalState) — "
            + "\(presenter.rehearsalState.hasPrefix("níveis=2") ? "ENTROU" : "MORTO")"
        )
        let realçadoNoFilho = presenter.rehearsalState
        await tecla(RehearsalKey.left, "\u{F702}", "menu ←")
        RehearsalStage.log(
            "menu ←: \(presenter.rehearsalState) — "
            + "\(presenter.rehearsalState.hasPrefix("níveis=1") ? "VOLTOU" : "MORTO")"
        )

        // ⏎ sobre um submenu abre o nível de baixo, como o NSMenu faz.
        await tecla(RehearsalKey.ret, "\r", "menu ⏎ sobre o submenu")
        RehearsalStage.log(
            "menu ⏎ sobre submenu: \(presenter.rehearsalState) — "
            + "\(presenter.rehearsalState.hasPrefix("níveis=2") ? "ABRIU o nível" : "MORTO")"
        )

        // ⏎ sobre um item de verdade executa e fecha. A prova é a mensagem
        // mudar de caixa — o realce entrou no filho em \(realçadoNoFilho).
        let caixaAntes = store.messages.first { $0.id == "m1" }?.bucket
        await tecla(RehearsalKey.ret, "\r", "menu ⏎ no item do submenu")
        let caixaDepois = store.messages.first { $0.id == "m1" }?.bucket
        RehearsalStage.log(
            "menu ⏎ no item (filho estava em \(realçadoNoFilho)): fechou=\(!presenter.isOpen), "
            + "caixa \(caixaAntes.map(String.init(describing:)) ?? "—") → "
            + "\(caixaDepois.map(String.init(describing:)) ?? "—") — "
            + "\(!presenter.isOpen && caixaAntes != caixaDepois ? "EXECUTOU e fechou" : "MORTO")"
        )

        // E Esc, no menu reaberto.
        driver.rightClick(at: driver.point(x: 300, fromTop: 150))
        await settle(0.7)
        await tecla(RehearsalKey.escape, "\u{1B}", "menu Esc")
        RehearsalStage.log(
            "menu Esc: aberto=\(presenter.isOpen) — "
            + "\(presenter.isOpen ? "MORTO (continuou aberto)" : "FECHOU")"
        )
        presenter.dismiss()
        await settle(0.3)
    }

    private func tecla(_ code: UInt16, _ characters: String, _ rótulo: String) async {
        driver.send(key: code, characters: characters)
        await settle(0.35)
        RehearsalStage.log("\(rótulo): \(ContextMenuPresenter.shared.rehearsalState)")
    }

    // MARK: - Utilidades

    private func responder() -> String {
        guard let responder = NSApp.keyWindow?.firstResponder else { return "nenhum" }
        return String(describing: type(of: responder))
    }

    /// Devolve o app ao estado em que um atalho tem chance de existir: ativo, e
    /// com a janela principal sendo a chave.
    ///
    /// **Não é enfeite do ensaio.** Sem app ativo `NSApp.keyWindow` é `nil`, e
    /// um `keyDown` que sai da fila nesse estado não chega a
    /// `performKeyEquivalent` de janela nenhuma: todo atalho mediria "morto"
    /// pelo motivo errado. Foi o que aconteceu na primeira rodada, quando abrir
    /// e fechar a janela 03 deixou o app sem janela-chave e ⌘K e ⌘R caíram
    /// juntos.
    private func focar() async {
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
        await settle(0.3)
    }

    private var estado: String {
        "ativo=\(NSApp.isActive) chave=\(window.isKeyWindow)"
    }

    private func closeExtras(keeping count: Int) async {
        for window in RehearsalWindows.visible().dropFirst(count) {
            window.close()
        }
        await settle(0.5)
        self.window.makeKeyAndOrderFront(nil)
        await settle(0.3)
    }

    private func settle(_ seconds: Double = 0.35) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}
