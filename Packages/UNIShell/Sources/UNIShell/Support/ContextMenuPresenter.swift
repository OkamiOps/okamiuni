import AppKit
import SwiftUI
import UNICore
import UNIDesign

/// A janela que segura um nível de menu.
///
/// Precisa poder virar janela-chave: o realce por ponteiro do SwiftUI depende
/// de área de rastreamento, e as setas do teclado precisam de um destino. Uma
/// `NSWindow` sem moldura recusa a chave por padrão — daí a subclasse.
final class MenuPanelWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// A `NSHostingView` do painel, que devolve o clique dado na **folga da
/// sombra**.
///
/// A janela é maior que o painel: a sombra do tema é desenhada dentro dela e
/// precisa de espaço. Sem isto, a auréola transparente de 12pt em volta do
/// painel engoliria cliques que visivelmente caem fora do menu.
final class MenuHostingView<Content: View>: NSHostingView<Content> {
    var contentInset: CGFloat = 0

    required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) não é usado") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.insetBy(dx: contentInset, dy: contentInset).contains(local) else {
            return nil
        }
        return super.hitTest(point)
    }
}

/// Quem abre, fecha e posiciona os painéis de menu de contexto.
///
/// ## Por que um só no app inteiro
///
/// O `NSMenu` garantia isso de graça: abrir um menu fecha o anterior, porque o
/// sistema roda um laço de rastreamento por vez. Trocado por painéis nossos, a
/// garantia passa a ser deste objeto — daí ser um `shared`. Dois menus abertos
/// ao mesmo tempo é o defeito mais óbvio que a migração poderia introduzir.
///
/// ## Por que janela, e não `overlay`
///
/// Um `overlay` vive dentro da janela do app e é recortado por ela: um menu
/// aberto na última linha da lista sairia cortado no rodapé. É o mesmo motivo
/// registrado em `ComposerSelect` para o `popover`. Aqui não dá para usar
/// `popover`: ele desenha o próprio recipiente (seta e fundo do sistema) e
/// ancora num retângulo de `View`, não no ponto do clique.
///
/// ## O que ele não faz
///
/// Não decide conteúdo (é `UNICore.ContextMenus`) e não decide posição (é
/// `UNICore.MenuPlacement`). Aqui é só AppKit: medir, criar janela, escutar
/// evento, fechar.
@MainActor
final class ContextMenuPresenter {
    static let shared = ContextMenuPresenter()

    /// Espaço em volta do painel, dentro da janela, para a sombra do tema
    /// caber. Ver `MenuHostingView`.
    static let shadowRoom: CGFloat = 12

    private struct Panel {
        let window: MenuPanelWindow
        let level: MenuLevel
        /// A linha do nível de cima que abriu este — `nil` no primeiro.
        let parentRow: Int?
    }

    private var panels: [Panel] = []
    private var host: NSWindow?
    private var theme: Theme = .tinta
    private var run: ((ContextCommand) -> Void)?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []

    var isOpen: Bool { !panels.isEmpty }

    /// O estado do menu em uma linha, para o ensaio no app real aferir o que a
    /// tecla fez. Só leitura, e só isto: `KeyboardRehearsal` precisa saber
    /// quantos níveis estão abertos e qual linha está realçada no mais fundo.
    var rehearsalState: String {
        guard let level = panels.last?.level else { return "fechado" }
        let title: String
        switch level.highlightedEntry {
        case .item(let item): title = item.title
        case .submenu(let name, _): title = name
        case .separator, .none: title = "—"
        }
        return "níveis=\(panels.count) realce=\(level.highlighted.map(String.init) ?? "nenhum") “\(title)”"
    }

    private init() {}

    // MARK: - Abrir

    /// Abre o menu com o canto no ponto do clique, em coordenadas de **tela**.
    func present(
        _ entries: [ContextMenuEntry],
        at point: CGPoint,
        in host: NSWindow?,
        theme: Theme,
        run: @escaping (ContextCommand) -> Void
    ) {
        dismiss()
        guard !entries.isEmpty else { return }

        self.host = host
        self.theme = theme
        self.run = run

        let level = MenuLevel(entries: entries)
        let bounds = visibleFrame(containing: point)
        let (view, size) = build(level, depth: 0)
        let placement = MenuPlacement.root(anchor: point, size: size, bounds: bounds)
        open(Panel(window: window(view, frame: outset(placement.frame)),
                   level: level, parentRow: nil))
        installMonitors()
    }

    /// Fecha tudo. Idempotente — chamada de todo caminho de saída.
    func dismiss() {
        for panel in panels.reversed() { close(panel.window) }
        panels = []
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        run = nil
        // A janela do app volta a ser a chave; sem isto o teclado fica sem
        // destino depois que o menu some.
        host?.makeKey()
        host = nil
    }

    // MARK: - Montagem de um nível

    /// Monta a `View` do nível e devolve a medida **do painel**, já sem a folga
    /// da sombra.
    private func build(_ level: MenuLevel, depth: Int) -> (MenuHostingView<AnyView>, CGSize) {
        let room = Self.shadowRoom
        let panel = ContextMenuPanel(
            level: level,
            onHover: { [weak self] row in self?.hover(row, at: depth) },
            onActivate: { [weak self] row in self?.activate(row, at: depth) }
        )
        let root = AnyView(
            panel
                .padding(room)
                .theme(theme)
                .environment(\.displayScale, scale())
        )
        let view = MenuHostingView(rootView: root)
        view.contentInset = room
        view.layoutSubtreeIfNeeded()
        let fitting = view.fittingSize
        return (view, CGSize(
            width: max(fitting.width - 2 * room, 0),
            height: max(fitting.height - 2 * room, 0)
        ))
    }

    private func window(_ view: MenuHostingView<AnyView>, frame: CGRect) -> MenuPanelWindow {
        let window = MenuPanelWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        // A sombra é a do tema, desenhada por dentro. A do sistema por cima
        // dela seria a segunda sombra — e seria a do sistema.
        window.hasShadow = false
        window.level = .popUpMenu
        window.acceptsMouseMovedEvents = true
        window.animationBehavior = .none
        window.contentView = view
        window.setFrame(frame, display: false)
        return window
    }

    private func open(_ panel: Panel) {
        panels.append(panel)
        if let host { host.addChildWindow(panel.window, ordered: .above) }
        panel.window.orderFrontRegardless()
        panel.window.makeKey()
    }

    private func close(_ window: MenuPanelWindow) {
        host?.removeChildWindow(window)
        window.orderOut(nil)
        window.close()
    }

    // MARK: - Submenu

    /// Abre o submenu da linha `row` do nível `depth`, se ela for um.
    private func openSubmenu(_ row: Int, at depth: Int) {
        guard panels.indices.contains(depth) else { return }
        let parent = panels[depth]
        guard parent.level.entries.indices.contains(row),
              case .submenu(_, let items) = parent.level.entries[row],
              !items.isEmpty
        else { return }

        // Já aberto pela mesma linha: não refaz. Sem esta guarda, um `onHover`
        // repetido pisca o submenu a cada movimento do ponteiro.
        if panels.count > depth + 1, panels[depth + 1].parentRow == row { return }
        closeLevels(deeperThan: depth)

        guard let rowTop = parent.level.rowTops[row] else { return }
        let level = MenuLevel(entries: items.map { ContextMenuEntry.item($0) })
        let (view, size) = build(level, depth: depth + 1)
        let parentPanel = inset(parent.window.frame)
        let placement = MenuPlacement.submenu(
            parent: parentPanel,
            // `rowTops` é y-para-baixo, a partir do topo do painel; a tela é
            // y-para-cima. Esta é a única conversão do arquivo.
            rowTop: parentPanel.maxY - rowTop,
            size: size,
            bounds: visibleFrame(containing: CGPoint(x: parentPanel.maxX, y: parentPanel.maxY))
        )
        open(Panel(window: window(view, frame: outset(placement.frame)),
                   level: level, parentRow: row))
    }

    private func closeLevels(deeperThan depth: Int) {
        while panels.count > depth + 1 {
            close(panels.removeLast().window)
        }
        if let last = panels.last { last.window.makeKey() }
    }

    // MARK: - Ponteiro e teclado

    private func hover(_ row: Int, at depth: Int) {
        guard panels.indices.contains(depth) else { return }
        panels[depth].level.highlighted = row
        if case .submenu = panels[depth].level.entries[row] {
            openSubmenu(row, at: depth)
        } else {
            closeLevels(deeperThan: depth)
        }
    }

    private func activate(_ row: Int, at depth: Int) {
        guard panels.indices.contains(depth) else { return }
        let level = panels[depth].level
        guard level.entries.indices.contains(row) else { return }
        switch level.entries[row] {
        case .submenu:
            enterSubmenu(row, at: depth)
        case .item(let item):
            guard item.isEnabled else { return }
            let action = run
            dismiss()
            action?(item.command)
        case .separator:
            return
        }
    }

    /// A caixa que leva um `NSEvent` para dentro do ator principal.
    ///
    /// `NSEvent` não é `Sendable` e `MainActor.assumeIsolated` exige que o que
    /// entra e o que sai seja. O evento não atravessa fio nenhum — o monitor
    /// local já é chamado na thread principal —, e a caixa é o que diz isso ao
    /// compilador sem afrouxar nada de verdade.
    private struct EventBox: @unchecked Sendable {
        let event: NSEvent
    }

    /// Um monitor local cobre teclado e clique fora com um objeto só.
    ///
    /// Local, e não global: o que interessa é o evento que chega **ao app** —
    /// clique em outro app cai no `didResignActive` logo abaixo.
    private func installMonitors() {
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { event in
            let box = EventBox(event: event)
            let swallow = MainActor.assumeIsolated {
                ContextMenuPresenter.shared.handle(box.event)
            }
            return swallow ? nil : event
        }

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { ContextMenuPresenter.shared.dismiss() }
        })
        if let host {
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                         NSWindow.willCloseNotification] {
                observers.append(center.addObserver(
                    forName: name, object: host, queue: .main
                ) { _ in
                    MainActor.assumeIsolated { ContextMenuPresenter.shared.dismiss() }
                })
            }
        }
    }

    /// `true` engole o evento; `false` deixa passar.
    private func handle(_ event: NSEvent) -> Bool {
        guard isOpen else { return false }

        if event.type == .keyDown { return key(event) }

        // Clique dentro de um painel nosso é dos botões dele.
        if let window = event.window, panels.contains(where: { $0.window === window }) {
            return false
        }
        dismiss()
        // Um clique **esquerdo** fora só fecha o menu — é o que o `NSMenu`
        // fazia, e é o que impede que fechar um menu selecione outra linha por
        // engano. O direito passa, para o menu da superfície de baixo abrir no
        // mesmo gesto.
        return event.type != .rightMouseDown
    }

    /// Abre o submenu da linha e leva o realce para dentro dele.
    ///
    /// É o que `→` faz e o que `⏎` faz numa linha de submenu. Um caminho só
    /// para os dois: quando eram dois, `→` acabou caindo no de executar item.
    private func enterSubmenu(_ row: Int, at depth: Int) {
        openSubmenu(row, at: depth)
        guard panels.count > depth + 1 else { return }
        let child = panels[depth + 1].level
        child.highlighted = MenuKeyNavigation.first(in: child.entries)
    }

    /// A tecla não decide nada aqui: `MenuKeyNavigation.action` decide, e este
    /// método só executa. A decisão mora em `UNICore` porque é onde ela pode
    /// ser provada sem abrir janela — ver `MenuKeyActionTests`.
    private func key(_ event: NSEvent) -> Bool {
        guard let deepest = panels.indices.last else { return false }
        let level = panels[deepest].level
        let action = MenuKeyNavigation.action(
            forKeyCode: event.keyCode,
            highlighted: level.highlighted,
            in: level.entries,
            depth: deepest
        )
        switch action {
        case .close:
            dismiss()
        case .move(let step):
            level.move(step)
        case .activate(let row):
            activate(row, at: deepest)
        case .enterSubmenu(let row):
            enterSubmenu(row, at: deepest)
        case .leaveSubmenu:
            closeLevels(deeperThan: deepest - 1)
        case .nothing:
            break
        }
        // Nada de tecla vaza para a janela de baixo enquanto o menu está
        // aberto: era assim com o `NSMenu`, e um ⌘R disparado por trás de um
        // menu aberto seria defeito novo.
        return true
    }

    // MARK: - Geometria

    /// A área útil da tela que contém o ponto. Sem tela casada — ponto fora de
    /// tudo, monitor desligado no meio do gesto — cai na principal.
    private func visibleFrame(containing point: CGPoint) -> CGRect {
        let screen = NSScreen.screens.first { $0.frame.contains(point) }
            ?? NSScreen.main
        return screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func scale() -> CGFloat {
        host?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    /// Painel → janela (acrescenta a folga da sombra) e o contrário.
    private func outset(_ rect: CGRect) -> CGRect {
        rect.insetBy(dx: -Self.shadowRoom, dy: -Self.shadowRoom)
    }

    private func inset(_ rect: CGRect) -> CGRect {
        rect.insetBy(dx: Self.shadowRoom, dy: Self.shadowRoom)
    }
}
