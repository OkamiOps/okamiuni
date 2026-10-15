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
/// O harness de sempre desenha o conteúdo numa janela sem borda: ele prova o
/// layout e não prova o chrome. E o chrome é o que o brief manda conferir —
/// "os semáforos não podem estar espremidos no canto". Um semáforo mal
/// colocado **não aparece** num retrato sem barra de título, porque ali não há
/// semáforo nenhum.
///
/// Quem fotografa é o `JanelaReal`, o harness que a base já tinha para o
/// trilho. Ele importa por uma razão que custou um retrato errado neste ramo:
/// ele aplica o `.ignoresSafeArea(.container, edges: .top)` que
/// `OkamiUNIApp.barraColadaNoTopo()` aplica às cenas. Sem ele o
/// `NSHostingView` respeita a área segura da barra de título e empurra o
/// conteúdo 32pt para baixo — o cabeçalho descia, os dois ícones apareciam
/// numa segunda fileira abaixo das bolinhas, e a foto mostrava um defeito que
/// o app não tem.
@Suite("Retratos das janelas próprias", .serialized)
@MainActor
struct ModaisJanelaRenderTests {

    private static func store() async -> MailStore {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        return store
    }

    @Test("a janela do compromisso: semáforos com respiro, na linha do cabeçalho")
    func compromisso() async throws {
        let store = await Self.store()
        let item = try #require(store.agenda.first)
        for (nome, tema) in ModaisRenderTests.temas {
            let foto = try #require(JanelaReal.fotografar(
                EventWindow(store: store, itemID: item.id),
                size: CGSize(width: UNIWindow.Size.event.width, height: 700),
                theme: tema, named: "janela-compromisso-\(nome)"
            ))
            Self.afirmaSemaforos(foto, tema: nome)
        }
    }

    @Test("a janela da mensagem: 880×720, semáforos com respiro")
    func mensagem() async throws {
        let store = await Self.store()
        let message = try #require(store.messages.first)
        for (nome, tema) in ModaisRenderTests.temas {
            // O `.frame` explícito: sem ele o `NSHostingView` cresce com o
            // leitor (o corpo do email tem a altura que tiver) e a janela
            // acompanha — o retrato saía com 1370 de alto, que não é a medida
            // de abertura nenhuma. Aqui ela é a do desenho.
            let foto = try #require(JanelaReal.fotografar(
                MessageWindow(store: store, messageID: message.id)
                    .frame(width: UNIWindow.Size.message.width, height: UNIWindow.Size.message.height),
                size: UNIWindow.Size.message,
                theme: tema, named: "janela-mensagem-\(nome)"
            ))
            Self.afirmaSemaforos(foto, tema: nome)
        }
    }

    /// O que "não espremidos no canto" quer dizer, em números.
    ///
    /// O macOS deixa a fileira em x=8, encostada na quina. Nestas duas janelas
    /// ela é movida para 20 — o mesmo respiro que o trilho da janela principal
    /// tem (`TrafficLightLayout.railLeading`) — e centrada na faixa de
    /// cabeçalho de 52.
    ///
    /// Cai por mutação: tirar o `trafficLightsInWindowHeader()` devolve a
    /// fileira para x=8 e o centro para a linha nativa de 16.
    private static func afirmaSemaforos(_ foto: JanelaReal.Foto, tema: String) {
        let grupo = foto.grupo
        let fechar = foto.semaforos[0]

        #expect(
            fechar.minX >= 18,
            "\(tema): o fechar começa em \(fechar.minX) — espremido na quina"
        )
        #expect(
            abs(fechar.minX - TrafficLightLayout.windowRowLeading) <= 0.5,
            "\(tema): o fechar começa em \(fechar.minX), o desenho pede \(TrafficLightLayout.windowRowLeading)"
        )
        // Os três em ordem e na mesma linha.
        #expect(foto.semaforos[1].minX > fechar.minX, "\(tema)")
        #expect(foto.semaforos[2].minX > foto.semaforos[1].minX, "\(tema)")
        #expect(abs(grupo.height - fechar.height) <= 0.5, "\(tema): a fileira não está na mesma linha")

        // E o centro dela cai no meio da faixa de cabeçalho.
        let centro = grupo.midY
        let linha = TrafficLightLayout.windowCenterFromTop
        #expect(
            abs(centro - linha) <= 1,
            "\(tema): a fileira centra em \(centro), a faixa de \(TrafficLightLayout.windowBarHeight) pede \(linha)"
        )
        // A fileira inteira cabe antes de onde o conteúdo começa.
        #expect(
            grupo.maxX < WindowChrome.trafficLightInset + 6,
            "\(tema): a fileira termina em \(grupo.maxX)"
        )
        // E o conteúdo **não** foi empurrado pela área segura da barra: com o
        // `barraColadaNoTopo` do app ele começa no topo do quadro.
        #expect(foto.conteudo.minY <= 0.5, "\(tema): o conteúdo começa em \(foto.conteudo.minY)")
    }
}
