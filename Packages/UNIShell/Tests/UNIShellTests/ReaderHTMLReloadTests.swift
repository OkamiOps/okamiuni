import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit
@testable import UNIShell

/// O caminho dos "trinta segundos em branco **sem** o carregando".
///
/// A M3-21 desenhou a espera e ela não aparecia no caso do dono. O motivo é
/// este: o sinal `pintou` só nascia falso. A mensagem abre com as imagens
/// remotas bloqueadas — pinta em milissegundos, sinal ligado —, a pessoa aperta
/// "Carregar", e o **segundo** documento começa a descer com o sinal ainda
/// ligado da carga anterior. A `WebView` fica em branco, e nada na tela diz que
/// há algo vindo.
///
/// Aqui a rede é lenta de propósito (`ServidorDeImagem`, com atraso), que é a
/// única forma de olhar para o meio da carga.
@Suite("A segunda carga da mesma mensagem volta a mostrar a espera", .serialized)
@MainActor
struct ReaderHTMLReloadTests {

    @MainActor
    final class Caixa {
        var altura: CGFloat = 1
        var pintou = false
    }

    private static func corpo(
        _ endereco: String, remotas: Bool, caixa: Caixa
    ) -> ReaderHTMLBody {
        ReaderHTMLBody(
            html: "<p>Promoção</p><img src=\"\(endereco)\" width=\"20\" height=\"20\">",
            permiteRemotas: remotas,
            fundo: "#ffffff", tinta: "#1a1a1a", link: "#1155cc", fonte: "ui-serif",
            altura: Binding(get: { caixa.altura }, set: { caixa.altura = $0 }),
            pintou: Binding(get: { caixa.pintou }, set: { caixa.pintou = $0 })
        )
    }

    /// **A prova.** Com a imagem descendo devagar, o sinal está desligado
    /// durante a espera — a roda gira — e volta a ligar quando a mensagem pinta.
    @Test("Apertar «Carregar» volta a esperar, e a espera dura o que a rede durar")
    func aSegundaCargaVoltaAEsperar() async throws {
        ReaderWebSession.esvazia()
        let servidor = try ServidorDeImagem(preso: true)
        defer { servidor.para() }

        let caixa = Caixa()
        let bloqueada = Self.corpo(servidor.endereco, remotas: false, caixa: caixa)
        let coordenador = bloqueada.makeCoordinator()
        let web = WebViewQueNaoRouba(
            frame: NSRect(x: 0, y: 0, width: 500, height: 400),
            configuration: ReaderWebSession.configuracao()
        )
        web.navigationDelegate = coordenador

        // A abertura normal: imagens bloqueadas, pinta na hora.
        coordenador.carrega(em: web)
        for _ in 0..<200 where !caixa.pintou {
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(caixa.pintou)
        #expect(servidor.pedidos == 0, "a imagem remota saiu pela rede sem ninguém pedir")

        // O clique em "Carregar": mesma mensagem, imagens liberadas.
        coordenador.pai = Self.corpo(servidor.endereco, remotas: true, caixa: caixa)
        let comeco = Date()
        coordenador.carrega(em: web)

        // O instante é ancorado no que **aconteceu**, e não no relógio: o
        // servidor já recebeu o pedido e está **segurando** a imagem, então a
        // página não tem como ter acabado de carregar. É o meio da espera, sem
        // depender de máquina rápida ou lenta.
        for _ in 0..<400 where servidor.pedidos == 0 {
            try? await Task.sleep(for: .milliseconds(25))
        }
        #expect(servidor.pedidos == 1, "a segunda carga nem começou")
        #expect(
            !caixa.pintou,
            "o leitor continuou dizendo que a mensagem estava pintada enquanto ela baixava"
        )

        // E quando a imagem chega, a espera some sozinha.
        try? await Task.sleep(for: .milliseconds(300))
        #expect(!caixa.pintou, "a espera sumiu com a imagem ainda presa no servidor")
        servidor.solta()
        for _ in 0..<200 where !caixa.pintou {
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(caixa.pintou)
        #expect(servidor.pedidos == 1)
        // **A espera durou o que a rede durou.** Sem a geração, a resposta
        // atrasada da régua do documento **anterior** (a segunda passada que o
        // `didFinish` agenda 120ms depois) anunciava "pintou" logo no começo da
        // carga nova, e a espera sumia da tela com a mensagem ainda em branco.
        #expect(
            Date().timeIntervalSince(comeco) > 0.3,
            "a espera acabou antes da imagem chegar — a régua do documento velho respondeu pelo novo"
        )
    }

    /// Zerar `pageZoom` a cada 250 ms — o acompanhamento que media o cartaz
    /// tardio — faz a newsletter inteira piscar. A régua de acompanhamento
    /// mede a altura **sem** mexer no zoom.
    @Test("Acompanhar o cartaz tardio não zera o zoom")
    func acompanhamentoNaoZeraOZoom() async throws {
        ReaderWebSession.esvazia()
        let caixa = Caixa()
        let corpo = ReaderHTMLBody(
            html: """
                <table width="640" cellpadding="0" cellspacing="0">
                <tr><td style="width:640px;height:120px">Olá, Marcos</td></tr>
                </table>
                """,
            permiteRemotas: true,
            fundo: "#ffffff", tinta: "#1a1a1a", link: "#1155cc", fonte: "ui-serif",
            altura: Binding(get: { caixa.altura }, set: { caixa.altura = $0 }),
            pintou: Binding(get: { caixa.pintou }, set: { caixa.pintou = $0 })
        )
        let coordenador = corpo.makeCoordinator()
        let web = WebViewQueNaoRouba(
            frame: NSRect(x: 0, y: 0, width: 500, height: 400),
            configuration: ReaderWebSession.configuracao()
        )
        web.navigationDelegate = coordenador
        coordenador.carrega(em: web)
        for _ in 0..<200 where !caixa.pintou {
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(caixa.pintou)
        let zoom = web.pageZoom
        #expect(zoom < 1, "a tabela de 640 num painel de 500 deveria ter encolhido")
        for _ in 0..<4 {
            coordenador.remede(web)
            try? await Task.sleep(for: .milliseconds(50))
            #expect(
                abs(web.pageZoom - zoom) < 0.001,
                "o acompanhamento zerou o zoom (\(web.pageZoom) contra \(zoom))"
            )
        }
    }

    /// O teto é curto: imagem remota presa não pode girar a espera para sempre.
    @Test("O teto da espera é curto porque só começa quando a navegação acaba")
    func oTetoEDaRegua() {
        #expect(ReaderHTMLSection.tetoDaEspera <= .seconds(8))
        #expect(ReaderHTMLSection.tetoDaEspera > .zero)
    }

    /// O cartaz da Symphonic: 2 MB, `height=auto`, pixel de rastreio que não
    /// termina. O teto pinta o título; o cartaz chega depois e empurra o
    /// texto para fora da WebView. A régua tem de crescer de novo.
    @Test("A régua cresce quando o cartaz chega depois do teto")
    func aReguaCresceComOCartazTardio() async throws {
        ReaderWebSession.esvazia()
        let servidor = try ServidorDeImagem(preso: true, imagem: ServidorDeImagem.cartazAlto)
        defer { servidor.para() }

        let caixa = Caixa()
        let corpo = ReaderHTMLBody(
            html: """
                <p>One Week Away //</p>
                <img src="\(servidor.endereco)" width="40" style="height:auto;display:block" alt="">
                <p>We're bringing the Symphonic Social to Hamburg</p>
                """,
            permiteRemotas: true,
            fundo: "#ffffff", tinta: "#1a1a1a", link: "#1155cc", fonte: "ui-serif",
            altura: Binding(get: { caixa.altura }, set: { caixa.altura = $0 }),
            pintou: Binding(get: { caixa.pintou }, set: { caixa.pintou = $0 })
        )
        let coordenador = corpo.makeCoordinator()
        let web = WebViewQueNaoRouba(
            frame: NSRect(x: 0, y: 0, width: 500, height: 400),
            configuration: ReaderWebSession.configuracao()
        )
        web.navigationDelegate = coordenador
        coordenador.carrega(em: web)

        for _ in 0..<400 where !caixa.pintou {
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(caixa.pintou, "o teto não pintou com o cartaz preso")
        let antes = caixa.altura

        servidor.solta()
        for _ in 0..<80 where caixa.altura <= antes + 80 {
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(
            caixa.altura > antes + 80,
            "a régua não cresceu depois do cartaz (antes \(antes), depois \(caixa.altura))"
        )
    }
}

