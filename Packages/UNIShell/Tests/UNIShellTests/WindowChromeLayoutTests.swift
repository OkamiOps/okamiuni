import AppKit
import Testing
import CoreGraphics
import SwiftUI
import UNIDesign
@testable import UNIShell

/// A barra superior é o que o dono do projeto mais olha, e o que ele já
/// reclamou duas vezes. Estes testes travam a ordem do novo shell e a linha
/// média em que os semáforos
/// nativos passam a cair.
@Suite("Barra superior — posições e ordem")
struct WindowChromeLayoutTests {

    // MARK: ordem horizontal

    @Test("a ordem dos controles é a que o dono pediu, da esquerda para a direita")
    func controlOrderIsLocked() {
        #expect(
            WindowChrome.controlOrder == [
                .sidebarToggle,
                .lockup,
                .search,
                .tabs,
                .agendaToggle,
                .themePicker,
                .accounts,
            ]
        )
    }

    @Test("todo controle aparece uma vez só, e nenhum some da barra")
    func everyControlAppearsExactlyOnce() {
        let order = WindowChrome.controlOrder
        #expect(order.count == 7)
        #expect(order.count == Set(order).count)
        #expect(order.contains(.compose) == false)
        #expect(Set(order) == Set(ChromeControl.allCases.filter { $0 != .compose }))
    }

    @Test("o lockup abre o conteúdo e a conta fecha a barra")
    func shellAnchorsStayInPlace() {
        let order = WindowChrome.controlOrder
        guard
            let lockup = order.firstIndex(of: .lockup),
            let search = order.firstIndex(of: .search),
            let accounts = order.firstIndex(of: .accounts)
        else {
            Issue.record("a barra perdeu um dos controles estruturais do redesenho")
            return
        }
        #expect(order.first == .sidebarToggle, "a esquerda tem de abrir com o botão da lateral")
        #expect(lockup == 1, "a marca deve ficar logo após o botão da lateral")
        #expect(search == 2, "a busca deve ficar entre a marca e as abas")
        #expect(accounts == order.count - 1, "a conta deve fechar a barra")
    }

    @Test("só a busca cede largura")
    func onlySearchIsFlexible() {
        #expect(WindowChrome.flexibleControl == .search)
        #expect(WindowChrome.controlOrder.contains(.search))
    }

    @Test("a barra usa o lockup oficial completo nos dois temas")
    @MainActor
    func fullBrandLockup() {
        #expect(WindowChrome.lockupAssetName(isDark: false) == "uni-lockup-light")
        #expect(WindowChrome.lockupAssetName(isDark: true) == "uni-lockup-dark")
        #expect(WindowChrome.lockupSize == CGSize(width: 138, height: 38))
        #expect(WindowChrome.lockupSize.height <= WindowChrome.height)
    }

    @Test("o lockup completo não corta a busca nem os controles na janela compacta")
    @MainActor
    func fullLockupFitsSupportedWidths() throws {
        // O catálogo pertence ao bundle do app, não ao pacote UNIShell. Para
        // fotografar a View de produção no teste offscreen, registra o mesmo
        // PNG oficial no cache nomeado do AppKit durante este caso apenas.
        var repositoryRoot = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repositoryRoot.deleteLastPathComponent() }
        let assetURL = repositoryRoot.appending(
            path: "App/Resources/Assets.xcassets/uni-lockup-light.imageset/uni-lockup-light.png"
        )
        let lockupImage = try #require(NSImage(contentsOf: assetURL))
        let assetName = NSImage.Name(WindowChrome.lockupAssetName(isDark: false))
        #expect(lockupImage.setName(assetName))
        defer { lockupImage.setName(nil) }

        for width in [CGFloat(860), 1_200, 1_440] {
            let recorder = ChromeFrameRecorder()
            let chrome = WindowChrome(
                workspace: .constant(.mail),
                query: .constant(""),
                accountCount: 3,
                onToggleSidebar: {},
                onToggleAgenda: {}
            )
            .environment(ThemeStore())
            .onPreferenceChange(ChromeControlFrames.self) { frames in
                MainActor.assumeIsolated { recorder.frames = frames }
            }

            _ = try #require(Render.snapshot(
                chrome,
                named: "window-chrome-lockup-\(Int(width))",
                size: CGSize(width: width, height: WindowChrome.height),
                theme: .tinta
            ))

            let frames = recorder.frames.sorted { $0.minX < $1.minX }
            #expect(frames.count == WindowChrome.controlOrder.count)
            guard frames.count == WindowChrome.controlOrder.count else { continue }

            let lockup = frames[1]
            let search = frames[2]
            let rightEdge = try #require(frames.last?.maxX)
            #expect(abs(lockup.width - WindowChrome.lockupSize.width) < 0.5)
            #expect(abs(lockup.height - WindowChrome.lockupSize.height) < 0.5)
            #expect(search.width >= WindowChrome.searchMinimumWidth)
            #expect(rightEdge > width - 13)
            #expect(rightEdge <= width - 11)

            for pair in zip(frames, frames.dropFirst()) {
                #expect(pair.0.maxX <= pair.1.minX)
            }
        }
    }

    // MARK: alinhamento vertical

    /// O macOS centra os semáforos na barra de título de 32pt que reserva mesmo
    /// numa janela `.hiddenTitleBar`. Medido por acessibilidade antes da
    /// Task S: quadro y=8..24, centro em 16.
    @Test("a posição nativa dos semáforos é a que foi medida na janela")
    func nativeCenterIsWhatWasMeasured() {
        #expect(TrafficLightLayout.nativeBarHeight == 32)
        #expect(TrafficLightLayout.nativeCenterFromTop == 16)
    }

    /// Os botões que `NSWindow.standardWindowButton` devolve têm 14pt de lado —
    /// medido na hierarquia de views. O quadro de acessibilidade é maior (16pt),
    /// mas quem posiciona é o `frame`.
    @Test("na barra de 64pt o semáforo nasce em y=35 e fica com centro em y=22")
    func trafficLightLandsOnTheBarsMidline() {
        #expect(TrafficLightLayout.buttonOriginY(barHeight: 64, buttonHeight: 14) == 35)
        #expect(TrafficLightLayout.centerFromTop(barHeight: 64, buttonHeight: 14) == 22)
    }

    /// Os semáforos ficam na linha nativa; a fileira de controles desce para o
    /// centro da toolbar e ganha a folga superior pedida pelo design.
    @Test("os controles têm respiro no centro da toolbar")
    func trafficLightMeetsOurControls() {
        #expect(WindowChrome.centerY == WindowChrome.height / 2)
        #expect(WindowChrome.height == 64)
        let semaphore = TrafficLightLayout.centerFromTop(
            barHeight: WindowChrome.height, buttonHeight: 14
        )
        #expect(WindowChrome.centerY > semaphore)
        #expect(WindowChrome.centerY - 19 >= 12)
    }

    /// O semáforo nativo nasce com centro em 16 numa barra de título comum.
    /// Nós o movemos para 22, que é onde Chrome, Claude, VSCode e Codex põem a
    /// fileira de controles — e é para lá que a nossa também foi.
    @Test("o semáforo desce 6pt do padrão nativo para a linha da plataforma")
    func movesToThePlatformLine() {
        let before = TrafficLightLayout.nativeCenterFromTop
        let after = TrafficLightLayout.centerFromTop(barHeight: 64, buttonHeight: 14)
        #expect(before == 16)
        #expect(after == 22)
        #expect(after - before == 6)
    }

    /// O `NSTitlebarContainerView` ainda precisa crescer junto: um `NSView`
    /// desenha fora dos próprios limites mas não recebe clique fora deles. Com
    /// centro em 22, o semáforo termina em y=29 — dentro dos 32pt da barra
    /// nativa por pouco, mas o container cresce porque os **nossos** controles
    /// ocupam a faixa inteira e precisam receber clique.
    @Test("o semáforo cabe na barra nativa, mas a faixa de controles não")
    func containerMustGrowForOurControls() {
        let bottom = TrafficLightLayout.centerFromTop(barHeight: 64, buttonHeight: 14) + 7
        #expect(bottom == 29)
        #expect(bottom <= TrafficLightLayout.nativeBarHeight)
        // A faixa de conteúdo vai até 44 (2 × 22) e passa dos 32 nativos.
        #expect(TrafficLightLayout.contentCenterFromTop * 2 > TrafficLightLayout.nativeBarHeight)

        let originIn64 = TrafficLightLayout.buttonOriginY(barHeight: 64, buttonHeight: 14)
        #expect(originIn64 >= 0)
        #expect(originIn64 + 14 <= 64, "o botão tem de caber inteiro na barra de 64pt")
    }

    /// A barra de título mora em coordenadas do `NSThemeFrame`, que não é
    /// invertido: ela encosta no topo da janela, então a origem sobe junto com a
    /// altura. Numa janela de 916pt de altura com barra de 64, isso é y=852.
    @Test("o container da barra de título cresce a partir do topo da janela")
    func containerFrameGrowsFromTheTop() {
        let frame = TrafficLightLayout.containerFrame(
            windowSize: CGSize(width: 1440, height: 916), barHeight: 64
        )
        #expect(frame == CGRect(x: 0, y: 852, width: 1440, height: 64))
    }

    @Test(
        "o container acompanha a janela em toda largura que a Task R prevê",
        arguments: [
            (CGSize(width: 880, height: 916), CGRect(x: 0, y: 852, width: 880, height: 64)),
            (CGSize(width: 1200, height: 916), CGRect(x: 0, y: 852, width: 1200, height: 64)),
            (CGSize(width: 1440, height: 916), CGRect(x: 0, y: 852, width: 1440, height: 64)),
            (CGSize(width: 860, height: 632), CGRect(x: 0, y: 568, width: 860, height: 64)),
        ]
    )
    func containerFollowsTheWindow(size: CGSize, expected: CGRect) {
        #expect(TrafficLightLayout.containerFrame(windowSize: size, barHeight: 64) == expected)
    }
}

@MainActor
private final class ChromeFrameRecorder {
    var frames: [CGRect] = []
}

@Suite("Duplo clique na barra")
struct TitleBarDoubleClickTests {

    /// O ajuste do sistema tem três valores e os três importam: cravar zoom
    /// ignoraria quem escolheu minimizar, e quem escolheu "nada" veria a janela
    /// se mexer sem ter pedido.
    @Test("cada valor do ajuste do sistema mapeia para a sua ação", arguments: [
        ("Maximize", DoubleClickAction.zoom),
        ("Minimize", DoubleClickAction.miniaturize),
        ("None", DoubleClickAction.none),
        (nil as String?, DoubleClickAction.zoom),   // padrão de fábrica
    ])
    func actionForSetting(setting: String?, expected: DoubleClickAction) {
        #expect(DoubleClickAction.forSystemSetting(setting) == expected)
    }

    @Test("um valor desconhecido cai no padrão em vez de não fazer nada")
    func unknownFallsBackToZoom() {
        #expect(DoubleClickAction.forSystemSetting("SomethingElse") == .zoom)
    }

    // MARK: - Roteamento do clique

    /// ## Por que os três testes de roteamento que estavam aqui saíram
    ///
    /// Eles montavam uma `NSView` de barra, punham a `CatcherView` dentro e
    /// afirmavam que `bar.hitTest(ponto)` devolvia a captura. Passavam. E o
    /// recurso continuou morto na tela do dono do projeto por duas tarefas
    /// inteiras.
    ///
    /// O ensaio no app real (`--ensaiar-barra`) mediu o que eles não podiam
    /// medir. Perguntado quem responde ao ponto da barra **no app**, o AppKit
    /// respondeu `AppKitWindowHostingView`: a hospedeira do SwiftUI responde por
    /// si e nunca alcança uma `NSView` pendurada como fundo. E quando a captura
    /// foi para cima e passou a ser devolvida pelo `hitTest`, `mouseDown`
    /// continuou não sendo chamado — o SwiftUI consulta o `hitTest` da view
    /// hospedada e entrega o evento à máquina de gestos dele mesmo assim.
    ///
    /// Uma barra de mentira num teste nunca teria dito isso. O que ficou no
    /// lugar é o que um teste consegue afirmar de verdade: a captura **não
    /// disputa** o clique de ninguém (abaixo), a decisão de onde a barra é
    /// vazia é `TitleBarHitZone` (`UNICore`, `TitleBarHitZoneTests`), e o
    /// caminho do evento é provado rodando o app.

    /// A `CatcherView` é âncora de medida, não captura de clique. Devolver
    /// qualquer coisa que não seja `nil` a poria por cima dos controles da
    /// barra — e o duplo clique não chega por aqui de qualquer forma.
    @Test("a âncora do duplo clique nunca rouba o clique de ninguém")
    @MainActor
    func theAnchorNeverStealsAClick() {
        let bar = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 64))
        let catcher = CatcherView(frame: bar.bounds)
        catcher.barHeight = 64
        bar.addSubview(catcher)

        #expect(catcher.hitTest(NSPoint(x: 420, y: 48)) == nil)
        #expect(catcher.hitTest(NSPoint(x: 100, y: 22)) == nil)
        #expect(bar.hitTest(NSPoint(x: 420, y: 48)) === bar)
    }

    /// A âncora fala o idioma do SwiftUI: y para baixo, origem no canto
    /// superior esquerdo. É o que faz `convert(_:from: nil)` devolver um ponto
    /// comparável às molduras que o `WindowChrome` mede — sem isso a decisão
    /// leria a barra de cabeça para baixo e trocaria vazio por controle.
    @Test("a âncora mede no mesmo sentido em que o SwiftUI desenha")
    @MainActor
    func theAnchorIsFlippedLikeSwiftUI() {
        #expect(CatcherView(frame: .zero).isFlipped)
    }
}
