import AppKit
import Foundation

/// O palco compartilhado pelos ensaios no app real.
///
/// ## Por que existe
///
/// `SwipeRehearsal` provou que um defeito de evento só se pega com o evento de
/// verdade: o gesto foi consertado três vezes no modelo, com teste verde, e
/// continuou morto na mão do dono do projeto. A Task AQ trouxe dois defeitos da
/// mesma família (atalhos de teclado e duplo clique na barra), então o
/// instrumento virou regra do projeto e ganhou casa própria aqui.
///
/// O que este arquivo dá aos ensaios: escrever no stderr e **sintetizar**
/// `NSEvent`s dentro do processo. Nada aqui toca no mouse nem no teclado da
/// máquina — não há `CGEvent` postado no sistema, nem `osascript`. Os eventos
/// nascem por `NSEvent.keyEvent`/`NSEvent.mouseEvent` e entram por
/// `NSApp.sendEvent` ou `NSWindow.sendEvent`, o mesmo cano por onde um evento
/// real do sistema chegaria à janela depois de a `NSApplication` o receber.
enum RehearsalStage {
    /// stderr, não `print`: `stdout` é bufferizado quando não é terminal e a
    /// linha se perde quando o app encerra — exatamente quando alguém foi
    /// conferir o resultado do ensaio.
    static func log(_ text: String) {
        FileHandle.standardError.write(Data(("[ensaio] " + text + "\n").utf8))
    }

    /// O contêiner é o único lugar em que o sandbox deixa escrever.
    static func framePath(_ name: String) -> String {
        (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("ensaio-\(name).png")
    }
}

/// Os códigos de tecla virtuais que os ensaios usam. São os do
/// `Carbon.HIToolbox.Events`, escritos aqui para o ensaio não puxar o Carbon.
enum RehearsalKey {
    /// ⌘A — "selecionar tudo". O ensaio de contas o usa para apagar o palpite
    /// de um campo antes de digitar por cima.
    static let a: UInt16 = 0
    static let r: UInt16 = 15
    static let n: UInt16 = 45
    static let k: UInt16 = 40
    static let ret: UInt16 = 36
    static let e: UInt16 = 14
    static let f: UInt16 = 3
    static let escape: UInt16 = 53
    /// A tecla de apagar, sem modificador. É a única do ensaio que **não** vai
    /// por `performKeyEquivalent` — ver `UNIShell.BareKeyMonitor`.
    static let delete: UInt16 = 51
    static let left: UInt16 = 123
    static let right: UInt16 = 124
    static let down: UInt16 = 125
    static let up: UInt16 = 126
}

/// Sintetiza e entrega eventos a uma janela do próprio processo.
@MainActor
final class RehearsalDriver {
    let window: NSWindow
    private var eventNumber = 70_000

    init(window: NSWindow) {
        self.window = window
    }

    var contentSize: CGSize { window.contentView?.bounds.size ?? .zero }

    /// Um ponto dado em coordenadas **do topo para baixo** (como o SwiftUI
    /// desenha) convertido para as da janela, em que o y cresce para cima.
    func point(x: CGFloat, fromTop y: CGFloat) -> NSPoint {
        NSPoint(x: x, y: contentSize.height - y)
    }

    // MARK: - Teclado

    /// Manda uma tecla pela **fila do próprio app**.
    ///
    /// `NSApp.postEvent(_:atStart:)`, e não `window.sendEvent` nem
    /// `NSApp.sendEvent`, por dois motivos.
    ///
    /// Um: um atalho com ⌘ nunca chega ao `keyDown:` de ninguém — quem o
    /// resolve é `NSApplication.sendEvent`, que oferece o evento ao menu
    /// principal e depois ao `performKeyEquivalent(with:)` da janela-chave, e é
    /// ali que o `keyboardShortcut` do SwiftUI escuta.
    ///
    /// Dois, e este só apareceu no ensaio: entregar o evento na mão deixa
    /// `NSApp.currentEvent` com o evento **anterior**. Quem decide roteamento
    /// lendo `NSApp.currentEvent` — o `RightClickCatcher` faz exatamente isso —
    /// passa a decidir pelo passado, e o ensaio mediria um app que não existe.
    /// Posto na fila, o evento sai por `nextEventMatchingMask` como qualquer
    /// outro e `currentEvent` é ele. Continua tudo dentro do processo: nada é
    /// postado no sistema.
    func send(key code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = []) {
        for phase in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: phase,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: code
            ) else {
                RehearsalStage.log("tecla \(code) não pôde ser sintetizada")
                return
            }
            NSApp.postEvent(event, atStart: false)
        }
    }

    /// Manda uma tecla **direto para a janela**, sem passar pela fila do app.
    ///
    /// A fila (`send(key:…)`) é obrigatória para atalho com ⌘: quem os resolve
    /// é `NSApplication.sendEvent`, e ela só corre no app **ativo**. Isso custa
    /// caro para um ensaio que roda enquanto o dono trabalha: ou ele rouba a
    /// frente da máquina, ou não mede nada — e um app lançado por trás nem
    /// sempre ganha a ativação, o que faz o mesmo ensaio passar numa rodada e
    /// falhar na seguinte sem nada ter mudado.
    ///
    /// Um caractere digitado num campo de texto não precisa de nada disso: ele
    /// vai do `sendEvent` da janela ao `keyDown:` do primeiro respondedor, que
    /// é o editor de campo, e daí ao `interpretKeyEvents`. É o mesmo cano por
    /// onde a tecla real chega depois que a `NSApplication` a entregou à
    /// janela — só que sem exigir a frente da tela.
    ///
    /// Serve para tecla **sem** modificador de comando. Para atalho, use
    /// `send(key:…)` e ative o app antes.
    func type(key code: UInt16, characters: String, in target: NSWindow? = nil) {
        let window = target ?? self.window
        for phase in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: phase,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: code
            ) else {
                RehearsalStage.log("tecla \(code) não pôde ser sintetizada")
                return
            }
            window.sendEvent(event)
        }
    }

    // MARK: - Mouse

    /// Um clique completo (down + up) com a contagem pedida, entregue à janela.
    ///
    /// `clickCount` é o campo que o AppKit preenche sozinho num clique de
    /// verdade e é o que `CatcherView.mouseDown` lê para saber que foi duplo.
    func click(at point: NSPoint, clickCount: Int = 1, in target: NSWindow? = nil) {
        let window = target ?? self.window
        post(.leftMouseDown, at: point, clickCount: clickCount, in: window)
        post(.leftMouseUp, at: point, clickCount: clickCount, in: window)
    }

    /// Um clique entregue **direto na janela**, sem depender de o app estar na
    /// frente da tela — o par de `type(key:…)`, e pela mesma razão.
    ///
    /// ## A soltura vai para a fila **antes** da pressão, e isso não é capricho
    ///
    /// Um `NSButton`, um `NSTextField` e boa parte do SwiftKit que o SwiftUI
    /// desenha tratam o clique com um **laço de rastreio**: ao receber o
    /// `mouseDown` eles param ali dentro chamando `nextEventMatchingMask`, à
    /// espera da soltura. Entregue só por `sendEvent`, a soltura nunca passa
    /// pela fila — e o laço espera por um sistema que não vai mandar nada. O
    /// app trava inteiro, com a thread principal parada: nem o relógio de
    /// guarda deste ensaio disparava, porque ele também é `@MainActor`.
    ///
    /// Isto aconteceu de verdade, e o sintoma enganava: o ensaio parava em
    /// pontos diferentes a cada rodada, conforme qual view do caminho usava
    /// laço de rastreio.
    ///
    /// Pondo a soltura na fila **primeiro**, o laço já a encontra lá quando
    /// começa a procurar, e devolve na hora. Quem não usa laço nenhum recebe a
    /// soltura síncrona logo depois, como sempre; a cópia da fila chega a
    /// seguir e é ignorada — soltura sem pressão não aciona coisa alguma.
    ///
    /// Quem decide roteamento lendo `NSApp.currentEvent` — o `RightClickCatcher`
    /// faz isso — **não** pode ser medido assim; para esses, `click(at:)`.
    func hit(at point: NSPoint, clickCount: Int = 1, in target: NSWindow? = nil) {
        let window = target ?? self.window
        guard let down = mouseEvent(.leftMouseDown, at: point, clickCount: clickCount, in: window),
              let up = mouseEvent(.leftMouseUp, at: point, clickCount: clickCount, in: window),
              let upDaFila = mouseEvent(.leftMouseUp, at: point, clickCount: clickCount, in: window)
        else { return }
        NSApp.postEvent(upDaFila, atStart: false)
        window.sendEvent(down)
        window.sendEvent(up)
    }

    private func mouseEvent(
        _ type: NSEvent.EventType, at point: NSPoint, clickCount: Int, in window: NSWindow
    ) -> NSEvent? {
        eventNumber += 1
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: eventNumber,
            clickCount: clickCount,
            pressure: type == .leftMouseUp ? 0 : 1
        ) else {
            RehearsalStage.log("evento \(type) não pôde ser sintetizado")
            return nil
        }
        return event
    }

    /// Duplo clique como o sistema o entrega: dois pares down/up, o segundo com
    /// `clickCount: 2`. Mandar só o par de `clickCount: 2` faria o alvo receber
    /// um duplo clique que nunca foi antecedido por um simples — e é o simples
    /// que põe a janela em foco e arma o arraste.
    func doubleClick(at point: NSPoint, in target: NSWindow? = nil) {
        click(at: point, clickCount: 1, in: target)
        click(at: point, clickCount: 2, in: target)
    }

    func rightClick(at point: NSPoint, in target: NSWindow? = nil) {
        let window = target ?? self.window
        post(.rightMouseDown, at: point, clickCount: 1, in: window)
        post(.rightMouseUp, at: point, clickCount: 1, in: window)
    }

    private func post(
        _ type: NSEvent.EventType, at point: NSPoint, clickCount: Int, in window: NSWindow
    ) {
        eventNumber += 1
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: eventNumber,
            clickCount: clickCount,
            pressure: type == .leftMouseUp || type == .rightMouseUp ? 0 : 1
        ) else {
            RehearsalStage.log("evento \(type) não pôde ser sintetizado")
            return
        }
        // Pela fila, como as teclas — ver a nota em `send(key:…)`. É o que faz
        // `NSApp.currentEvent` valer o evento corrente, e sem isso o
        // `RightClickCatcher` decide o roteamento lendo o evento anterior.
        NSApp.postEvent(event, atStart: false)
    }

    // MARK: - Foto

    func shoot(_ name: String) {
        guard let content = window.contentView,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            RehearsalStage.log("sem bitmap para \(name)")
            return
        }
        content.cacheDisplay(in: content.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        let path = RehearsalStage.framePath(name)
        do {
            try png.write(to: URL(fileURLWithPath: path))
            RehearsalStage.log("foto \(path)")
        } catch {
            RehearsalStage.log("escrita negada em \(path) — \(error)")
        }
    }
}

/// O censo de janelas do app, que é como os ensaios de teclado sabem se ⌘R e ⌘N
/// abriram alguma coisa.
@MainActor
enum RehearsalWindows {
    /// Só as janelas visíveis que o app desenha — painéis de menu de contexto e
    /// janelas de serviço do AppKit ficam de fora, senão o censo oscila sozinho.
    static func visible() -> [NSWindow] {
        NSApp.windows.filter { $0.isVisible && !($0 is MenuPanelWindow) }
    }

    /// O título que a janela declara ao sistema. É o que o menu Janela ▸ mostra
    /// — e, no ensaio, o que separa uma janela de resposta de uma de
    /// encaminhamento sem ler estado interno nenhum.
    static func title(of window: NSWindow) -> String { window.title }

    static func census() -> String {
        let titles = visible().map { window in
            // O identificador é o que separa uma cena da outra: duas janelas do
            // app têm o mesmo título, e foi por isso que o primeiro ensaio não
            // percebeu que ⌘N estava abrindo a janela errada.
            // O identificador da janela principal é o tipo inteiro da árvore
            // SwiftUI — meia tela de log por linha. As cenas com id, que são o
            // que o ensaio precisa distinguir, começam por "uni.".
            let raw = window.identifier?.rawValue
                ?? (window.title.isEmpty ? "«sem título»" : window.title)
            let name = raw.hasPrefix("uni.") ? raw : "«principal»"
            return "\(name) [\(Int(window.frame.width))×\(Int(window.frame.height))]"
        }
        return "\(titles.count) janela(s): \(titles.joined(separator: ", "))"
    }
}
