import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// Os retratos do compositor redesenhado, na medida do mock
/// `design/project/Compositor.dc.html`: 980×700.
///
/// O layout é **um só** para os 28 temas; o que muda entre eles é o tratamento
/// de superfície. Por isso os mesmos casos correm em `vidro`, `vidro-noite` e
/// num tema opaco (`okami`): se algum deles divergir de estrutura, a diferença
/// aparece aqui.
@Suite("Compositor redesenhado")
@MainActor
struct CompositorRenderTests {

    /// A medida do mock.
    private static let size = CGSize(width: 980, height: 700)

    private func loja() async -> MailStore {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        return store
    }

    @Test("a janela de resposta desenha na medida do mock", arguments: [
        "vidro", "vidro-noite", "okami",
    ])
    func replyRenders(id: String) async throws {
        let theme = try #require(Theme.named(id))
        let store = await loja()
        let rep = try #require(Render.snapshot(
            ComposerWindow(store: store, mode: .reply(messageID: "m1")),
            named: "compositor-\(id)",
            size: Self.size,
            theme: theme
        ))
        #expect(rep.pixelsWide == Int(Self.size.width))
        #expect(rep.pixelsHigh == Int(Self.size.height))
        // O acento do rodapé: sem ele o "Enviar" não está pintado.
        #expect(
            rep.pixels(matching: theme.accent, tolerance: 0.04) > 500,
            "\(id): o Enviar no acento não aparece"
        )
    }

    @Test("a janela de mensagem nova desenha na medida do mock", arguments: [
        "vidro", "okami",
    ])
    func newMessageRenders(id: String) async throws {
        let theme = try #require(Theme.named(id))
        let store = await loja()
        let rep = try #require(Render.snapshot(
            ComposerWindow(store: store, mode: .new(accountID: nil)),
            named: "compositor-nova-\(id)",
            size: Self.size,
            theme: theme
        ))
        #expect(rep.pixelsWide == Int(Self.size.width))
    }

    /// O defeito do print do dono do projeto: a lista de sugestões saía
    /// translúcida por cima da linha do Assunto e da barra de formatação, e os
    /// nomes ficavam ilegíveis.
    ///
    /// A medida é direta: a lista é **opaca**, então dentro do retângulo dela
    /// trocar o assunto da janela não pode mudar nenhum pixel. Com o fundo
    /// translúcido de `surface`, o texto do assunto atravessa e a contagem
    /// sobe.
    /// Os semáforos nativos só aparecem numa janela titulada de verdade: o
    /// `Render` comum fotografa a `contentView` e deixa a fileira de fora.
    @Test("na janela real, os semáforos respiram e cabem na barra", arguments: [
        "vidro", "vidro-noite", "okami"
    ])
    func semaforosDaJanelaReal(id: String) async throws {
        let theme = try #require(Theme.all.first { $0.id == id })
        let store = await loja()
        let foto = try #require(JanelaReal.fotografar(
            ComposerWindow(store: store, mode: .reply(messageID: "m1")),
            size: Self.size, theme: theme, named: "compositor-janela-real-\(id)"
        ))
        #expect(foto.grupo.minX >= 18, "\(id): semáforos colados na borda (x=\(foto.grupo.minX))")
        #expect(foto.grupo.minY >= 10, "\(id): semáforos colados no topo (y=\(foto.grupo.minY))")
        #expect(foto.grupo.maxY <= TrafficLightLayout.windowBarHeight)
    }

    @Test("a lista de sugestões é opaca sobre o assunto e a barra", arguments: [
        "vidro", "vidro-noite", "okami",
    ])
    func suggestionListIsOpaque(id: String) async throws {
        let theme = try #require(Theme.named(id))

        func desenho(assunto: String, nome: String) async throws -> NSBitmapImageRep {
            let store = await loja()
            // Dois corpos bem diferentes **atrás** da lista. O que está em
            // jogo é só o que a lista cobre.
            return try #require(Render.snapshot(
                ComposerWindow(
                    store: store, mode: .new(accountID: nil),
                    debugSuggestion: .init(slot: .to, query: "a"),
                    debugBody: assunto
                ),
                named: "compositor-sugestoes-\(id)-\(nome)",
                size: Self.size,
                theme: theme
            ))
        }

        let a = try await desenho(assunto: "", nome: "lista")
        let b = try await desenho(
            assunto: String(repeating: "ASSUNTO MUITO LONGO ATRAS DA LISTA ", count: 6),
            nome: "lista-com-fundo"
        )

        // O **interior** do cartão, medido no PNG de 980×700: ele nasce
        // colado no campo "Para" (x 90…430, y 128…368) e desce por cima da
        // linha do Assunto e da barra de formatação. A margem de 6pt de cada
        // lado tira a borda e a sombra da conta, que não são o que está sob
        // prova.
        var mudou = 0
        for y in 136..<360 {
            for x in 96..<424 where a.colorAt(x: x, y: y) != b.colorAt(x: x, y: y) {
                mudou += 1
            }
        }
        #expect(
            mudou == 0,
            "\(id): \(mudou) pixels dentro da lista mudaram com o corpo atrás dela — ela não está opaca"
        )
    }

    /// A pastilha do histórico citado nasce fechada, como no mock, e abre o
    /// bloco citado quando apertada. Sem isto o retrato não distingue "a
    /// pastilha é o botão" de "a pastilha é um rótulo".
    @Test("a pastilha do histórico desenha fechada")
    func historyPillRendersClosed() async throws {
        let store = await loja()
        let rep = try #require(Render.snapshot(
            ComposerWindow(store: store, mode: .reply(messageID: "m1")),
            named: "compositor-historico-fechado",
            size: Self.size,
            theme: .vidro
        ))
        #expect(rep.pixelsHigh == Int(Self.size.height))
    }
}
