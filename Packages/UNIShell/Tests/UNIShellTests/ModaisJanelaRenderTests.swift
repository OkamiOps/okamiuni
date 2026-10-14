import AppKit
import Foundation
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// As duas janelas **próprias** — compromisso e mensagem — fotografadas numa
/// `NSWindow` de verdade, com título e semáforos nativos.
///
/// ## Por que não basta o `Render`
///
/// O harness desenha o conteúdo numa janela sem borda: ele prova o layout e
/// não prova o chrome. E o chrome é justamente o que o brief manda conferir —
/// "os semáforos não podem estar espremidos no canto". Um semáforo mal
/// alinhado **não aparece** num retrato sem barra de título, porque ali não há
/// semáforo nenhum.
///
/// Aqui a janela tem `.titled` e `.fullSizeContentView`, como as cenas do app,
/// e o caso mede onde o AppKit pôs os três botões: o retrato sai do
/// `cacheDisplay` da view de moldura, que é a única maneira de a foto incluir
/// o que o sistema desenha por cima do conteúdo.
///
/// A janela fica a −50.000pt, nunca é trazida à frente e é fechada no fim.
@Suite("Retratos das janelas próprias", .serialized)
@MainActor
struct ModaisJanelaRenderTests {

    private static var destino: URL? { Render.outputDirectory }

    /// Monta a janela titulada, hospeda a view, fotografa a moldura inteira e
    /// devolve onde cada semáforo ficou.
    private static func janela<V: View>(
        _ view: V, size: CGSize, theme: Theme, named nome: String
    ) throws -> (close: NSRect, minimize: NSRect, zoom: NSRect, barra: CGFloat) {
        let window = NSWindow(
            contentRect: NSRect(x: -50_000, y: -50_000, width: size.width, height: size.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = NSHostingView(
            rootView: view
                .theme(theme)
                .environment(\.locale, Locale(identifier: "pt_BR"))
                .environment(\.displayScale, 1)
                .frame(width: size.width, height: size.height)
        )
        window.orderBack(nil)
        defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        window.contentView?.layoutSubtreeIfNeeded()

        let close = try #require(window.standardWindowButton(.closeButton))
        let minimize = try #require(window.standardWindowButton(.miniaturizeButton))
        let zoom = try #require(window.standardWindowButton(.zoomButton))
        let container = try #require(close.superview?.superview)

        if let dir = destino, let moldura = window.contentView?.superview {
            let rep = try #require(moldura.bitmapImageRepForCachingDisplay(in: moldura.bounds))
            moldura.cacheDisplay(in: moldura.bounds, to: rep)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("\(nome).png"))
            }
        }

        // Em coordenadas da janela, com a origem no topo — que é como o
        // desenho conta.
        func deCima(_ view: NSView) -> NSRect {
            let naJanela = view.convert(view.bounds, to: nil)
            return NSRect(
                x: naJanela.minX,
                y: window.frame.height - naJanela.maxY,
                width: naJanela.width, height: naJanela.height
            )
        }
        return (deCima(close), deCima(minimize), deCima(zoom), container.frame.height)
    }

    private static func store() async -> MailStore {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        return store
    }

    @Test("a janela do compromisso: semáforos na linha, e não espremidos no canto")
    func compromisso() async throws {
        let store = await Self.store()
        let item = try #require(store.agenda.first)
        for (nome, tema) in ModaisRenderTests.temas {
            let luzes = try Self.janela(
                EventWindow(store: store, itemID: item.id),
                size: CGSize(width: UNIWindow.Size.event.width, height: 700),
                theme: tema, named: "janela-compromisso-\(nome)"
            )
            Self.afirmaSemaforos(luzes, tema: nome)
        }
    }

    @Test("a janela da mensagem: 880×720, semáforos na linha")
    func mensagem() async throws {
        let store = await Self.store()
        let message = try #require(store.messages.first)
        for (nome, tema) in ModaisRenderTests.temas {
            let luzes = try Self.janela(
                MessageWindow(store: store, messageID: message.id),
                size: UNIWindow.Size.message,
                theme: tema, named: "janela-mensagem-\(nome)"
            )
            Self.afirmaSemaforos(luzes, tema: nome)
        }
    }

    /// O que "não espremidos no canto" quer dizer, em números.
    ///
    /// O macOS põe o primeiro botão a 20pt da borda esquerda e os três com
    /// 20pt de passo. A altura: o centro deles tem de cair na linha que a
    /// barra desta janela usa (`TrafficLightLayout.contentCenterFromTop`), e
    /// não no topo absoluto — era essa a queixa do dono na janela de resposta.
    private static func afirmaSemaforos(
        _ luzes: (close: NSRect, minimize: NSRect, zoom: NSRect, barra: CGFloat),
        tema: String
    ) {
        // O **x** é da plataforma: o AppKit põe a fileira onde ela fica em
        // qualquer janela titulada, e este projeto não a move na horizontal
        // (só o trilho recolhido o faz, com `compactRow`). O que se afirma
        // aqui é o que é nosso: que os três estão lado a lado, em ordem, e que
        // o nosso conteúdo **começa depois deles** — que é o "não espremidos
        // no canto" do brief. Com o conteúdo por cima, a bolinha fica embaixo
        // de um botão e deixa de ser clicável.
        #expect(luzes.close.minX > 0, "\(tema): o fechar saiu da janela")
        #expect(luzes.minimize.minX > luzes.close.minX, "\(tema)")
        #expect(luzes.zoom.minX > luzes.minimize.minX, "\(tema)")
        let fimDaFileira = luzes.zoom.maxX
        let inicioDoConteudo = WindowChrome.trafficLightInset
        #expect(
            fimDaFileira < inicioDoConteudo,
            "\(tema): a fileira termina em \(fimDaFileira), o conteúdo começa em \(inicioDoConteudo)"
        )
        // Os três na mesma linha.
        #expect(abs(luzes.close.midY - luzes.minimize.midY) < 0.6, "\(tema)")
        #expect(abs(luzes.close.midY - luzes.zoom.midY) < 0.6, "\(tema)")
        // E essa linha é a do conteúdo da barra, com um ponto de folga.
        let centro = luzes.close.midY
        let linha = TrafficLightLayout.contentCenterFromTop
        #expect(
            abs(centro - linha) <= 1.5,
            "\(tema): o centro dos semáforos caiu em \(centro), e a barra alinha em \(linha)"
        )
        #expect(luzes.barra > 0, "\(tema)")
    }
}
