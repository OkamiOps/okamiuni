import AppKit
import SwiftUI

/// A conta que põe os semáforos nativos no meio de uma barra mais alta que a
/// barra de título do sistema.
///
/// O macOS fixa a barra de título de uma janela `.hiddenTitleBar` em 32pt e
/// centra os três botões nela — centro em y=16 contando do topo da janela,
/// medido por acessibilidade. Nossa barra tem 64pt, mas mantém a fileira em
/// y=22 para seguir o alinhamento dos controles nativos da plataforma.
///
/// `NSTitlebarAccessoryViewController` **não** resolve: medido, o AppKit encaixa
/// o acessório num `NSTitlebarAccessoryClipView` de 32pt e a barra de título não
/// cresce um ponto. Vale para `.left`, e o `contentLayoutRect` também não se
/// mexe. Está registrado no relatório da Task P e reproduzido no da Task S.
///
/// O que resolve é crescer o `NSTitlebarContainerView` na mão e recentrar os
/// botões dentro dele. É API pública — as views vêm de
/// `NSWindow.standardWindowButton(_:)` e o resto é `NSView.frame`.
///
/// Crescer o container importa tanto quanto mover o botão: um `NSView` desenha
/// fora dos próprios limites mas **não** recebe clique fora deles. Empurrar o
/// botão 13pt para baixo dentro de um container de 32pt o deixaria visível e
/// morto.
enum TrafficLightLayout {
    /// Onde o macOS deixa o centro dos botões numa janela `.hiddenTitleBar`,
    /// contado do topo da janela. Medido por acessibilidade: quadro y=8..24.
    static let nativeCenterFromTop: CGFloat = 16

    /// Altura da barra de título que o quadro da janela reserva mesmo escondida.
    /// É de onde sai o `nativeCenterFromTop` e é o valor para o qual o AppKit
    /// devolve o container toda vez que a janela é redimensionada.
    static let nativeBarHeight: CGFloat = 32

    /// `origin.y` do botão dentro da barra de título. A barra de título **não**
    /// é invertida — y cresce para cima —, mas como o botão fica centrado o
    /// número é o mesmo contado de qualquer um dos lados.
    /// Onde a plataforma põe a fileira de controles, contado do topo da janela.
    ///
    /// **22, e não o centro da barra.** Centrar numa barra de 64 dá 32, que é o
    /// que o protótipo desenha — mas o dono do projeto apontou que Chrome,
    /// Claude, VSCode, Codex e outros põem em 22, e que a nossa ficava
    /// visivelmente baixa ao lado deles. Medido no Chrome desta máquina: 22.
    ///
    /// A regra deste projeto para este caso já estava escrita: onde a medida do
    /// protótipo brigar com a convenção do macOS, **a plataforma vence**. Os
    /// semáforos são o exemplo canônico dela.
    ///
    /// A barra continua com 64pt; o conteúdo ocupa a faixa de cima e a folga
    /// fica embaixo, como nesses apps.
    static let contentCenterFromTop: CGFloat = 22

    static func buttonOriginY(barHeight: CGFloat, buttonHeight: CGFloat) -> CGFloat {
        barHeight - contentCenterFromTop - buttonHeight / 2
    }

    /// Onde o centro do botão cai, contado do topo da janela — a mesma
    /// referência que a acessibilidade devolve e que o brief usa.
    static func centerFromTop(barHeight: CGFloat, buttonHeight: CGFloat) -> CGFloat {
        barHeight - buttonOriginY(barHeight: barHeight, buttonHeight: buttonHeight) - buttonHeight / 2
    }

    /// O quadro que o `NSTitlebarContainerView` precisa ter para caber a barra
    /// inteira. Ele mora em coordenadas do `NSThemeFrame`, que não é invertido:
    /// a barra encosta no topo da janela, então a origem sobe com a altura.
    static func containerFrame(windowSize: CGSize, barHeight: CGFloat) -> CGRect {
        CGRect(
            x: 0,
            y: windowSize.height - barHeight,
            width: windowSize.width,
            height: barHeight
        )
    }
}

/// Mantém os semáforos centrados na barra enquanto a janela existir.
///
/// O AppKit devolve o container para 32pt em toda relayout da janela —
/// redimensionar, sair de tela cheia, trocar de tela. Por isso o alinhamento é
/// reaplicado por notificação em vez de uma vez só na criação.
@MainActor
final class TrafficLightAligner: NSObject {
    private let barHeight: CGFloat
    private weak var window: NSWindow?
    private var observing = false

    init(barHeight: CGFloat) {
        self.barHeight = barHeight
    }

    func attach(to window: NSWindow) {
        guard self.window !== window else { return }
        detach()
        self.window = window
        guard let container = Self.titlebarContainer(of: window) else { return }

        container.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(realign),
            name: NSView.frameDidChangeNotification, object: container
        )
        center.addObserver(
            self, selector: #selector(realign),
            name: NSWindow.didResizeNotification, object: window
        )
        center.addObserver(
            self, selector: #selector(realign),
            name: NSWindow.didExitFullScreenNotification, object: window
        )
        center.addObserver(
            self, selector: #selector(realign),
            name: NSWindow.didBecomeKeyNotification, object: window
        )
        observing = true
        align()
    }

    func detach() {
        if observing {
            NotificationCenter.default.removeObserver(self)
            observing = false
        }
        window = nil
    }

    @objc private func realign() {
        align()
    }

    /// Idempotente de propósito: a própria escrita no `frame` dispara
    /// `frameDidChange`, e é a comparação com o quadro desejado que corta a
    /// volta. Sem ela isto seria um laço.
    func align() {
        guard let window,
              // Em tela cheia o macOS esconde e reposiciona a barra sozinho;
              // crescer o container ali briga com a animação de revelar.
              !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton),
              let miniaturize = window.standardWindowButton(.miniaturizeButton),
              let zoom = window.standardWindowButton(.zoomButton),
              let titlebar = close.superview,
              let container = titlebar.superview
        else { return }

        let wanted = TrafficLightLayout.containerFrame(
            windowSize: window.frame.size, barHeight: barHeight
        )
        let buttons = [close, miniaturize, zoom]
        let aligned = buttons.allSatisfy {
            $0.frame.origin.y == TrafficLightLayout.buttonOriginY(
                barHeight: barHeight, buttonHeight: $0.frame.height
            )
        }
        guard container.frame != wanted || !aligned else { return }

        container.frame = wanted
        titlebar.frame = CGRect(origin: .zero, size: wanted.size)
        for button in buttons {
            button.frame.origin.y = TrafficLightLayout.buttonOriginY(
                barHeight: barHeight, buttonHeight: button.frame.height
            )
        }
    }

    private static func titlebarContainer(of window: NSWindow) -> NSView? {
        window.standardWindowButton(.closeButton)?.superview?.superview
    }
}

/// Ponte de tamanho zero para alcançar o `NSWindow` de dentro da própria
/// `WindowChrome`. Existe para que a barra saiba se alinhar sozinha, sem que
/// `OkamiUNIApp` precise saber que semáforos existem.
struct TrafficLightAlignment: NSViewRepresentable {
    let barHeight: CGFloat

    func makeCoordinator() -> TrafficLightAligner {
        TrafficLightAligner(barHeight: barHeight)
    }

    func makeNSView(context: Context) -> NSView {
        let view = WindowReachingView()
        view.barHeight = barHeight
        let aligner = context.coordinator
        view.onWindow = { window in aligner.attach(to: window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? WindowReachingView)?.barHeight = barHeight
        if let window = nsView.window {
            context.coordinator.attach(to: window)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: TrafficLightAligner) {
        MainActor.assumeIsolated { coordinator.detach() }
    }
}

/// `viewDidMoveToWindow` é o primeiro momento em que `self.window` existe — o
/// `makeNSView` roda antes da view entrar na hierarquia.
///
/// Ela também é a **régua da barra**: por ser um ponto de tamanho zero no canto
/// superior esquerdo da barra, a posição dela na janela **é** o topo da barra.
/// É o que `TrafficLightAudit` lê para comparar o cabeçalho com o semáforo sem
/// depender de bitmap nenhum.
final class WindowReachingView: NSView {
    var onWindow: ((NSWindow) -> Void)?
    /// A altura da barra que este ponto ancora.
    var barHeight: CGFloat = 0

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { onWindow?(window) }
    }
}

/// Mede, **dentro do processo**, o desencontro entre os botões do sistema e a
/// barra que a janela desenha.
///
/// ## Por que não por bitmap
///
/// A M3-21 mediu o alinhamento fotografando o `contentView` e não reproduziu o
/// defeito: **os semáforos não são desenhados ali**. Eles são views do AppKit
/// que moram no `NSThemeFrame`, fora do conteúdo — a foto mostra a barra e um
/// vazio onde eles estão. Uma medida que não pode ver metade do que compara não
/// é medida.
///
/// Aqui a fonte é a moldura de verdade: `NSWindow.standardWindowButton`, e a
/// posição real da barra na janela (o ponto de tamanho zero que o alinhador
/// pendura no canto superior esquerdo dela). Tudo contado **do topo da janela
/// para baixo**, que é a referência da regra da casa.
@MainActor
enum TrafficLightAudit {
    struct Leitura: Sendable {
        let janela: String
        /// Centro do botão de fechar, contado do topo da janela.
        let semaforo: CGFloat
        let miniaturizar: CGFloat
        let zoom: CGFloat
        /// Onde a barra custom começa, contada do topo da janela. **Zero na
        /// janela principal**; era 28 nas secundárias, e é esse o defeito.
        let barraTopo: CGFloat
        let barraAltura: CGFloat

        /// A linha em que o cabeçalho centra o que desenha.
        var linhaDoCabecalho: CGFloat { barraTopo + TrafficLightLayout.contentCenterFromTop }
        var diferenca: CGFloat { semaforo - linhaDoCabecalho }

        var descricao: String {
            let n = { (v: CGFloat) in String(format: "%.1f", v) }
            return "\(janela): fechar=\(n(semaforo)) min=\(n(miniaturizar)) zoom=\(n(zoom)) · "
                + "barra topo=\(n(barraTopo)) altura=\(n(barraAltura)) centro=\(n(linhaDoCabecalho)) · "
                + "diferença=\(n(diferenca))"
        }
    }

    /// Quanto de desencontro ainda é alinhamento. Um ponto: abaixo disso é
    /// arredondamento de tela, acima disso o olho vê.
    static let tolerancia: CGFloat = 1

    static func ler(_ window: NSWindow, nome: String) -> Leitura? {
        guard let close = window.standardWindowButton(.closeButton),
              let min = window.standardWindowButton(.miniaturizeButton),
              let zoom = window.standardWindowButton(.zoomButton),
              let raiz = window.contentView,
              let barra = procurar(WindowReachingView.self, in: raiz)
        else { return nil }
        let altura = window.frame.height
        let doTopo = { (view: NSView) -> CGFloat in
            altura - view.convert(view.bounds, to: nil).midY
        }
        let topoDaBarra = altura - barra.convert(barra.bounds, to: nil).maxY
        return Leitura(
            janela: nome,
            semaforo: doTopo(close), miniaturizar: doTopo(min), zoom: doTopo(zoom),
            barraTopo: topoDaBarra, barraAltura: barra.barHeight
        )
    }

    private static func procurar<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let found = view as? T { return found }
        for subview in view.subviews {
            if let found = procurar(type, in: subview) { return found }
        }
        return nil
    }
}

extension View {
    /// Põe os semáforos nativos desta janela na linha da plataforma — a mesma
    /// em que a barra desenha o que ela desenha.
    ///
    /// **Existia só na janela principal, e é o defeito da M3-21.** A `WindowChrome`
    /// mandava os botões do sistema para y=22 e centrava os controles dela lá; as
    /// outras cinco janelas (03, 04, 05, 06 e Configurações) tinham a barra
    /// própria e **não** tinham o alinhador, então os semáforos delas ficavam
    /// onde o macOS os deixa numa `.hiddenTitleBar` — centro em y=16 — enquanto
    /// o título ia para o meio da barra. Cinco pontos de desencontro, medidos,
    /// em toda janela que não fosse a principal.
    ///
    /// Uma linha por barra, e a regra da casa passa a valer nas seis.
    func trafficLightsOnTheLine(barHeight: CGFloat) -> some View {
        overlay(alignment: .topLeading) {
            TrafficLightAlignment(barHeight: barHeight)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
    }
}
