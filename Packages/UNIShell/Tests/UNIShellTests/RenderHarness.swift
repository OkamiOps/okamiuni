import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// Renderiza telas **fora da tela**, sem abrir janela e sem tocar em mouse ou
/// teclado da máquina. É assim que este projeto verifica aparência: dirigir a
/// interface com eventos sintéticos rouba o computador de quem está usando.
///
/// `ImageRenderer` desenha a hierarquia SwiftUI direto num bitmap. Não há
/// `NSWindow`, não há foco, não há ponteiro.
@MainActor
enum Render {

    /// Onde os PNGs saem. Vazio = não escreve (o padrão, para a suíte ficar rápida).
    static var outputDirectory: URL? {
        ProcessInfo.processInfo.environment["UNI_RENDER_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
    }

    /// Renderiza uma view num tamanho e tema dados e devolve o bitmap.
    ///
    /// Usa uma `NSWindow` posicionada **muito fora da área visível** e nunca
    /// trazida à frente. O AppKit desenha a hierarquia completa — inclusive
    /// `ScrollView`, `TextField` e tudo que tem respaldo nativo, que o
    /// `ImageRenderer` deixa em branco — mas a janela não aparece em tela, não
    /// vira janela-chave e não recebe evento nenhum. Nada de foco roubado.
    static func bitmap<V: View>(
        _ view: V,
        size: CGSize,
        theme: Theme,
        scale: CGFloat = 1
    ) -> NSBitmapImageRep? {
        // ATENÇÃO ao comparar texto de data com o app rodando: parte do código
        // formata com `Locale(identifier: "pt_BR")` fixo e parte com
        // `Locale.current`. `Locale.current` resolve contra as localizações
        // declaradas no bundle — o app tem, o bundle de teste não — então aqui
        // essas datas saem em inglês ("AUG 25") e no app saem em português
        // ("25 DE AGO."). Injetar `\.locale` no ambiente NÃO corrige: esses
        // formatadores leem `Locale.current` direto, sem passar pelo ambiente.
        //
        // Isso é inconsistência real do código, registrada para conserto. Até
        // lá, não relate a diferença de idioma aqui como defeito de aparência.
        // `displayScale` tem de casar com a densidade do bitmap, senão o
        // parâmetro `scale` é mentira. A janela do harness herda a escala do
        // monitor da máquina que roda a suíte — nesta, 1× — de modo que
        // `scale: 2` desenhava o dobro de pixels mas o SwiftUI continuava
        // achando que estava em 1×. Tudo que decide espessura pela escala da
        // tela (ver `Hairline.thickness(_:)`) media a tela errada, e o teste de
        // 2× verificava o desenho de 1× ampliado.
        let root = view
            .theme(theme)
            .environment(\.locale, Locale(identifier: "pt_BR"))
            .environment(\.displayScale, scale)
            .frame(width: size.width, height: size.height)

        let window = NSWindow(
            contentRect: NSRect(x: -50_000, y: -50_000, width: size.width, height: size.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)

        guard let content = window.contentView else { return nil }
        defer { window.close() }

        // Fotografa **até o quadro parar de mudar**, e não depois de um tempo
        // fixo.
        //
        // Aqui havia `RunLoop.run(until: +0.05)` e uma única captura. Cinquenta
        // milissegundos bastam numa máquina ociosa e não bastam numa carregada:
        // com a suíte inteira em paralelo, o SwiftUI às vezes não terminava o
        // segundo passe (o que resolve conteúdo preguiçoso) antes da foto, e o
        // teste que media o cartão da paleta contava linhas de um cartão pela
        // metade. Medido no commit intocado deste marco: uma falha em doze
        // rodadas da suíte, em dois testes diferentes da mesma família — o
        // instrumento sorteando, não o código quebrando.
        //
        // Dois quadros idênticos seguidos é o sinal de que o desenho assentou.
        // São sempre no mínimo dois passes (nunca menos trabalho do que antes),
        // e o teto de oito impede que conteúdo que nunca assenta pendure a
        // suíte — nesse caso vale o último quadro, que é o que a versão antiga
        // devolveria de qualquer jeito.
        var anterior: NSBitmapImageRep?
        for _ in 0..<8 {
            content.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            content.layoutSubtreeIfNeeded()

            // Em `scale: 2` o bitmap tem o dobro de pixels mas o mesmo tamanho
            // em pontos — é assim que uma tela Retina desenha. Importa: uma
            // borda de 0,5pt vira meio pixel lavado em 1× e um pixel nítido em
            // 2×, e defeito de contorno só aparece na segunda. Verificar em 1× e
            // concluir que está limpo já me enganou uma vez.
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width * scale),
                pixelsHigh: Int(size.height * scale),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else { return nil }
            rep.size = size
            content.cacheDisplay(in: content.bounds, to: rep)
            if let anterior, mesmosPixels(anterior, rep) { return rep }
            anterior = rep
        }
        return anterior
    }

    /// Dois bitmaps com o mesmo conteúdo? Comparação byte a byte do plano —
    /// `memcmp` sobre alguns megabytes é ordens de grandeza mais barato do que
    /// um passe de layout, e é o que deixa a espera ser "até assentar" em vez de
    /// "por tanto tempo".
    private static func mesmosPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Bool {
        guard a.bytesPerPlane == b.bytesPerPlane,
              let dadosA = a.bitmapData, let dadosB = b.bitmapData else { return false }
        return memcmp(dadosA, dadosB, a.bytesPerPlane) == 0
    }

    /// Renderiza e, se `UNI_RENDER_DIR` estiver definido, grava um PNG para
    /// inspeção humana. Devolve o bitmap de qualquer jeito.
    @discardableResult
    static func snapshot<V: View>(
        _ view: V,
        named name: String,
        size: CGSize,
        theme: Theme,
        scale: CGFloat = 1
    ) -> NSBitmapImageRep? {
        guard let rep = bitmap(view, size: size, theme: theme, scale: scale) else { return nil }
        if let dir = outputDirectory {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("\(name).png"))
            }
        }
        return rep
    }
}

/// Hospeda uma `View` numa janela fora da tela e lhe entrega um clique **dentro
/// do processo**.
///
/// Nasceu na M3-11 dentro de `ConversationStackClickTests` e mudou de casa aqui
/// porque deixou de ser da pilha: o botão "Entrar" da janela do compromisso
/// (M3-13) precisa do mesmo cano — um controle que se diz mudo só se
/// desmente com um clique.
///
/// A janela é a do `Render`: sem borda, a −50.000pt, nunca trazida à frente,
/// fechada no fim. Nada aqui toca no mouse nem no teclado da máquina — não há
/// `CGEvent` postado no sistema, nem `osascript`. O evento nasce por
/// `NSEvent.mouseEvent` e entra por `NSWindow.sendEvent`, o mesmo cano por onde
/// um clique real chegaria à janela depois de a `NSApplication` o receber.
@MainActor
enum CliqueDeEnsaio {

    static func em<V: View>(_ view: V, size: CGSize, aY y: CGFloat, x: CGFloat = 60) {
        let raiz = view
            .theme(.tinta)
            .environment(\.locale, Locale(identifier: "pt_BR"))
            .environment(\.displayScale, 1)
            // `topLeading`, e não o centro que o `frame` dá por padrão: as
            // coordenadas deste ensaio contam a partir da primeira linha da
            // pilha, e conteúdo centrado as faria depender da altura do que
            // está aberto.
            .frame(width: size.width, height: size.height, alignment: .topLeading)

        let window = NSWindow(
            contentRect: NSRect(x: -50_000, y: -50_000, width: size.width, height: size.height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: raiz)
        // **`orderBack` não é descuido, e é o que faz o clique existir.** Numa
        // janela nunca ordenada o `hitTest` acha a `View` certa e o `Button` do
        // SwiftUI não dispara: medido, o contador do clique fica em zero.
        //
        // A janela continua a −50.000pt, fora de qualquer monitor, e `orderBack`
        // a põe **atrás** de tudo: não vira janela-chave, não ativa o app, não
        // tira o foco de quem está usando a máquina.
        window.orderBack(nil)
        defer { window.close() }
        guard let content = window.contentView else { return }

        content.layoutSubtreeIfNeeded()
        assenta()
        content.layoutSubtreeIfNeeded()

        clique(at: NSPoint(x: x, y: size.height - y), in: window)

        assenta()
        content.layoutSubtreeIfNeeded()
        assenta()
    }

    /// O par pressão/soltura, entregue **direto à janela**.
    ///
    /// `RehearsalDriver.hit` faria o mesmo e mais um passo: pôr uma cópia da
    /// soltura na fila do `NSApp`, para os laços de rastreio do AppKit a
    /// encontrarem lá. Isso é indispensável no app e é fatal aqui — num processo
    /// de teste, mexer na fila do `NSApp` termina o laço de drenagem da `main` e
    /// o processo **sai com 0 no meio do teste**, sem uma linha de relatório (a
    /// saída foi rastreada até `exit` dentro de
    /// `swift_task_asyncMainDrainQueue`). Um `Button` do SwiftUI não usa laço de
    /// rastreio, então o par direto basta.
    private static func clique(at ponto: NSPoint, in window: NSWindow) {
        for (tipo, pressao) in [(NSEvent.EventType.leftMouseDown, Float(1)), (.leftMouseUp, 0)] {
            guard let evento = NSEvent.mouseEvent(
                with: tipo, location: ponto, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 70_001, clickCount: 1, pressure: pressao
            ) else { return }
            window.sendEvent(evento)
        }
    }

    /// Deixa o desenho assentar. É `RunLoop`, e não `Task.sleep`: o `.task` de
    /// uma `View` é agendado pelo laço de execução, e uma pausa de concorrência
    /// o deixa por correr — medido, a porta de corpo nunca era perguntada.
    private static func assenta() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }
}

@Suite("Renderização fora da tela")
@MainActor
struct RenderHarnessTests {

    @Test("a caixa de entrada renderiza sem janela, no tamanho pedido")
    func inboxRenders() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let rep = try #require(
            Render.snapshot(
                InboxScreen(store: store).environment(ThemeStore()),
                named: "inbox-tinta",
                size: CGSize(width: 1440, height: 916),
                theme: .tinta
            )
        )
        #expect(rep.pixelsWide == 1440)
        #expect(rep.pixelsHigh == 916)
    }

    /// A caixa "Tudo", que é onde as sete mensagens do design aparecem juntas
    /// nos dois grupos. A caixa que abre por padrão mostra três — o design
    /// filtra por triagem, não por dia.
    ///
    /// Renderizar não prova rótulo (a comparação é humana, olhando o PNG), mas
    /// prova que a lista inteira desenha sem estourar altura nem sumir. As
    /// asserções de conteúdo estão em `MessageListTests`.
    @Test("a caixa Tudo desenha as sete mensagens em dois grupos")
    func allBucketRenders() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        store.select(bucket: .all)
        #expect(store.visibleMessages.count == 7)
        #expect(MessageGroup.build(from: store.visibleMessages).map(\.label) == ["Hoje", "Ontem"])

        let rep = try #require(
            Render.snapshot(
                InboxScreen(store: store).environment(ThemeStore()),
                named: "inbox-tudo-tinta",
                size: CGSize(width: 1440, height: 916),
                theme: .tinta
            )
        )
        #expect(rep.pixelsWide == 1440)
    }

    /// A trilha recolhida a 62pt, onde "HOSTINGER" não cabe e vira "HOS".
    /// O PNG é para conferir que a marca curta não estoura os 40pt da pastilha.
    @Test("a trilha recolhida desenha a marca curta do host")
    func collapsedRailRenders() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        #expect(store.accounts.map { HostMark.rail($0.host) } == ["ZOH", "GMA", "HOS", "ICL"])

        let rep = try #require(
            Render.snapshot(
                SidebarRail(store: store),
                named: "trilha-recolhida-tinta",
                size: CGSize(width: PaneLayout.railWidth, height: 480),
                theme: .tinta
            )
        )
        #expect(rep.pixelsWide == Int(PaneLayout.railWidth))
    }

    /// A barra expandida a 236pt, onde o mesmo host aparece por extenso.
    @Test("a barra expandida desenha o host por extenso")
    func expandedSidebarRenders() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()

        let rep = try #require(
            Render.snapshot(
                FolderSidebar(store: store),
                named: "barra-expandida-tinta",
                size: CGSize(width: PaneLayout.expandedSidebarWidth, height: 700),
                theme: .tinta
            )
        )
        #expect(rep.pixelsWide == Int(PaneLayout.expandedSidebarWidth))
    }
}

@Suite("Porta de depuração de lançamento")
struct LaunchWindowRequestTests {

    @Test("sem bandeira, lançamento normal não abre janela nenhuma")
    func noFlagNoWindow() {
        #expect(LaunchWindowRequest.parse([]) == nil)
        #expect(LaunchWindowRequest.parse(["-NSDocumentRevisionsDebugMode", "YES"]) == nil)
    }

    @Test("cada bandeira mapeia para a cena dela", arguments: [
        ("--nova-mensagem", UNIWindow.newMessage),
        ("--responder", UNIWindow.composer),
        ("--responder-todos", UNIWindow.composer),
        ("--encaminhar", UNIWindow.composer),
        ("--mensagem", UNIWindow.message),
        ("--compromisso", UNIWindow.event),
    ])
    func flagMapsToScene(flag: String, expected: String) throws {
        let request = try #require(LaunchWindowRequest.parse([flag]))
        #expect(request.windowID == expected)
    }

    /// Três bandeiras abrem a **mesma** cena, e o que as distingue é a
    /// intenção que o valor carrega — a mesma que o menu manda por
    /// `openWindow`. Sem isso, `--encaminhar m1` abriria uma resposta.
    @Test("as três intenções da janela 03 chegam pelo valor, não pela cena")
    func composerFlagsCarryTheirIntent() throws {
        let responder = try #require(LaunchWindowRequest.parse(["--responder", "m1"]))
        #expect(ComposerRoute.parse(responder.value) == .reply(messageID: "m1"))

        let todos = try #require(LaunchWindowRequest.parse(["--responder-todos", "m1"]))
        #expect(ComposerRoute.parse(todos.value) == .replyAll(messageID: "m1"))

        let encaminhar = try #require(LaunchWindowRequest.parse(["--encaminhar=m1"]))
        #expect(ComposerRoute.parse(encaminhar.value) == .forward(messageID: "m1"))
    }

    @Test("o valor vem colado ou separado")
    func valueForms() throws {
        let inline = try #require(LaunchWindowRequest.parse(["--mensagem=m2"]))
        #expect(inline.value == "m2")
        let separate = try #require(LaunchWindowRequest.parse(["--mensagem", "m2"]))
        #expect(separate.value == "m2")
    }

    @Test("uma bandeira seguida de outra não engole a seguinte como valor")
    func flagIsNotAValue() throws {
        let request = try #require(LaunchWindowRequest.parse(["--mensagem", "--responder"]))
        #expect(request.windowID == UNIWindow.message)
        #expect(request.value == "")
    }

    @Test("só a primeira bandeira vale")
    func firstFlagWins() throws {
        let request = try #require(
            LaunchWindowRequest.parse(["--compromisso", "a1", "--nova-mensagem"])
        )
        #expect(request.windowID == UNIWindow.event)
        #expect(request.value == "a1")
    }

    @Test("bandeira desconhecida é ignorada, não confundida com as nossas")
    func unknownFlagIgnored() throws {
        #expect(LaunchWindowRequest.parse(["--nova-mensagem-falsa"]) == nil)
        let request = try #require(
            LaunchWindowRequest.parse(["--qualquer", "coisa", "--responder", "m1"])
        )
        #expect(request.windowID == UNIWindow.composer)
        #expect(request.value == "m1")
    }
}

// MARK: - Ler cor no bitmap

extension NSBitmapImageRep {
    /// Quantos pixels desta imagem são desta cor.
    ///
    /// Existe porque um punhado de testes de render afirmava só
    /// `rep.pixelsWide == <o número passado ao Render>` — o valor da linha de
    /// cima, verdadeiro por construção. Com `ComposerTextKit` forçado a
    /// `BodyStyle.default` (todo estilo de trecho some do desenho) os cinco
    /// continuavam passando. Contar os pixels de um realce é a medida que cai
    /// junto com o estilo.
    ///
    /// A tolerância é apertada de propósito: em `tinta`, `btn` e `surface`
    /// diferem 0,02, e uma folga que aceite ruído aceita as duas como iguais.
    func pixels(matching css: String, tolerance: Double = 0.02) -> Int {
        guard let token = TokenColor(css: css) else { return 0 }
        return pixels(matching: token, tolerance: tolerance)
    }

    func pixels(matching token: TokenColor, tolerance: Double = 0.02) -> Int {
        guard let wanted = token.nsColor.usingColorSpace(.sRGB) else { return 0 }
        var count = 0
        for y in 0..<pixelsHigh {
            for x in 0..<pixelsWide {
                guard let c = colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                guard c.alphaComponent > 0.9 else { continue }
                if abs(c.redComponent - wanted.redComponent) < tolerance,
                   abs(c.greenComponent - wanted.greenComponent) < tolerance,
                   abs(c.blueComponent - wanted.blueComponent) < tolerance {
                    count += 1
                }
            }
        }
        return count
    }

    /// Quantos pixels diferem entre dois desenhos do mesmo tamanho.
    func pixelsDiffering(from other: NSBitmapImageRep) -> Int {
        guard pixelsWide == other.pixelsWide, pixelsHigh == other.pixelsHigh else { return -1 }
        var count = 0
        for y in 0..<pixelsHigh {
            for x in 0..<pixelsWide where colorAt(x: x, y: y) != other.colorAt(x: x, y: y) {
                count += 1
            }
        }
        return count
    }
}

