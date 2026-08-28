import SwiftUI
import AppKit
import UNICore

/// Faz o duplo clique na nossa barra respeitar o ajuste do sistema.
///
/// Numa janela `.hiddenTitleBar` a barra de título nativa fica atrás do nosso
/// conteúdo, então o duplo clique nunca chega nela e a janela não faz o que o
/// usuário configurou em Ajustes do Sistema ▸ Área de Trabalho e Dock ▸
/// "Clicar duas vezes na barra de título de uma janela para".
///
/// O ajuste vive em `AppleActionOnDoubleClick` e tem três valores: `Maximize`
/// (o padrão, que é o "preencher a tela"), `Minimize` e `None`. Respeitamos os
/// três — cravar zoom ignoraria quem escolheu minimizar.
///
/// ## O que a Task AQ mudou, e por quê
///
/// A Task AL fez a `CatcherView` responder ao `hitTest` e provou o conserto
/// chamando `hitTest` nela, num teste. O dono do projeto respondeu que na
/// prática continuava morto, e o ensaio no app real (`--ensaiar-barra`) mostrou
/// por quê, em dois passos.
///
/// Primeiro: perguntado quem responde ao ponto da barra, o AppKit respondeu
/// `AppKitWindowHostingView` — a hospedeira do SwiftUI, que responde por si
/// mesma. Uma `NSView` pendurada como fundo nunca é alcançada.
///
/// Segundo, e este derrubou também a correção óbvia: pendurada como `overlay`,
/// a `CatcherView` **passou** a ser devolvida pelo `hitTest` — e `mouseDown`
/// continuou nunca sendo chamado. Está no log da mesma rodada:
/// `hit clicks=2 … super=CatcherView`, e nenhum `mouseDown`. Para o botão
/// esquerdo o SwiftUI consulta o `hitTest` da view hospedada e mesmo assim
/// entrega o evento à máquina de gestos dele.
///
/// Então o duplo clique deixou de disputar o teste de acerto. Ele chega por um
/// **monitor local de eventos**, que vê o clique antes do despacho e não
/// depende de empilhamento nenhum. A `CatcherView` continua na árvore só para
/// medir: deitada sobre a barra, ela converte o ponto da janela em ponto da
/// barra. Clique simples, arraste e os controles seguem exatamente como antes,
/// porque nada além do `clickCount == 2` é sequer examinado.
struct TitleBarDoubleClick: ViewModifier {
    /// As molduras dos controles da barra, no espaço da própria barra. Ver
    /// `ChromeControlFrames`.
    let controls: [CGRect]
    let barHeight: CGFloat

    func body(content: Content) -> some View {
        content.background(DoubleClickCatcher(controls: controls, barHeight: barHeight))
    }
}

extension View {
    func titleBarDoubleClick(controls: [CGRect], barHeight: CGFloat) -> some View {
        modifier(TitleBarDoubleClick(controls: controls, barHeight: barHeight))
    }
}

private struct DoubleClickCatcher: NSViewRepresentable {
    let controls: [CGRect]
    let barHeight: CGFloat

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.controls = controls
        view.barHeight = barHeight
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        // As molduras mudam com a largura da janela e com o tema (corpo da
        // fonte muda a largura das abas). Sem esta atualização a área vazia
        // ficaria congelada na primeira medição.
        view.controls = controls
        view.barHeight = barHeight
    }
}

/// A âncora do duplo clique. Interno, não `private`: os testes a instanciam.
/// Ver `TitleBarDoubleClickTests`.
///
/// Ela **não recebe o clique** — não participa do teste de acerto de ninguém.
/// O que ela faz é medir: está deitada exatamente sobre a barra, então
/// converter um ponto da janela nas coordenadas dela dá o ponto na barra, que é
/// o que a decisão precisa. O evento chega por um monitor local, ver
/// `installMonitor`.
final class CatcherView: NSView {
    var controls: [CGRect] = []
    var barHeight: CGFloat = 0
    private var monitor: Any?

    /// O espaço do SwiftUI tem o y para baixo; o do AppKit, para cima. As
    /// molduras chegam medidas pelo SwiftUI, então a view se declara virada
    /// para os dois falarem a mesma língua e a conversão não ficar espalhada.
    override var isFlipped: Bool { true }

    /// **Invisível para o mouse, sempre.**
    ///
    /// Foi tentado o contrário nesta mesma tarefa, e o ensaio derrubou: com a
    /// captura por cima, devolvendo `self` no segundo clique, o `hitTest`
    /// devolvia `CatcherView` — e `mouseDown` **nunca era chamado**. O log do
    /// ensaio mostra as duas coisas na mesma rodada. Quem hospeda a
    /// `NSViewRepresentable` é o SwiftUI, e para o botão esquerdo ele consulta
    /// o `hitTest` da view e ainda assim entrega o evento à própria máquina de
    /// gestos dele. Insistir por aqui é discutir com o SwiftUI; o monitor
    /// abaixo simplesmente não passa por ele.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// O monitor nasce e morre com a janela. Fora dela a view não tem o que
    /// medir, e um monitor vivo depois disso escutaria cliques de uma janela
    /// que já não é a dela.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { removeMonitor(); return }
        window.isMovableByWindowBackground = true
        installMonitor()
    }

    /// O caminho por onde o duplo clique de verdade chega.
    ///
    /// Um monitor local vê o evento **antes** de a `NSApplication` o despachar,
    /// então ele não depende do teste de acerto do SwiftUI nem da ordem em que
    /// as views se empilham. É o mesmo instrumento que o menu de contexto usa
    /// para escutar teclado e clique fora (`ContextMenuPresenter`), e é o
    /// padrão do AppKit quando o alvo é a janela e não uma view.
    ///
    /// O que ele **não** toca: só o `clickCount == 2` é examinado. O clique
    /// simples passa intacto, e é ele que arma o arraste da janela pelo fundo
    /// (`isMovableByWindowBackground`) — arrastar a barra continua igual.
    private func installMonitor() {
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            let box = EventBox(event: event)
            let engoliu = MainActor.assumeIsolated {
                self?.handle(box.event) ?? false
            }
            return engoliu ? nil : event
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// `true` engole o evento.
    private func handle(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, event.clickCount == 2 else { return false }
        let local = convert(event.locationInWindow, from: nil)
        guard TitleBarHitZone.isEmptyArea(local, barHeight: barHeight, controls: controls) else {
            return false
        }
        Self.performSystemAction(on: window)
        // Engolido: o segundo clique já foi consumido pela janela. Deixá-lo
        // seguir faria a superfície de baixo receber um clique que o usuário
        // deu na barra.
        return true
    }

    /// `NSEvent` não é `Sendable` e `MainActor.assumeIsolated` exige que o que
    /// entra e o que sai seja. O evento não atravessa fio nenhum — o monitor
    /// local já é chamado na thread principal. Mesma caixa de
    /// `ContextMenuPresenter`, pelo mesmo motivo.
    private struct EventBox: @unchecked Sendable {
        let event: NSEvent
    }

    static func performSystemAction(on window: NSWindow?) {
        guard let window else { return }
        let setting = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
        switch DoubleClickAction.forSystemSetting(setting) {
        case .zoom: window.performZoom(nil)
        case .miniaturize: window.performMiniaturize(nil)
        case .none: break
        }
    }
}

/// As molduras dos controles da barra, colhidas pelo próprio SwiftUI.
///
/// A captura do duplo clique precisa saber onde **não** clicar, e o único que
/// sabe isso é quem faz o layout: as larguras mudam com a janela, com a
/// quantidade de contas no texto da busca e com o corpo da fonte do tema.
/// Cravar números aqui seria a mesma classe de erro que a Task AQ veio
/// desfazer — supor o que o app faz em vez de perguntar a ele.
struct ChromeControlFrames: PreferenceKey {
    static let defaultValue: [CGRect] = []

    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// Publica a moldura deste controle no espaço nomeado da barra.
    func chromeControlFrame(in space: String) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ChromeControlFrames.self,
                    value: [proxy.frame(in: .named(space))]
                )
            }
        )
    }
}

/// O que o duplo clique faz, segundo o ajuste do sistema. Fora da `View` para
/// poder ser testado — um `NSView` não se instancia num teste sem janela.
enum DoubleClickAction: Equatable {
    case zoom, miniaturize, none

    /// `AppleActionOnDoubleClick`. Ausente ou desconhecido cai em `zoom`, que é
    /// o padrão de fábrica do macOS — nunca em `none`, que deixaria a janela
    /// muda sem ninguém ter pedido.
    static func forSystemSetting(_ value: String?) -> DoubleClickAction {
        switch value {
        case "Minimize": .miniaturize
        case "None": .none
        default: .zoom
        }
    }
}
