import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit
@testable import UNIShell

/// "Sair da mensagem e voltar custa os mesmos trinta segundos, toda vez."
///
/// E custava: o leitor joga fora o bloco de HTML a cada abertura
/// (`.id(message.id)`), e a `WebView` nova baixava as imagens do remetente
/// outra vez, inteiras. Desde a M3-22 a página já pintada é **guardada** —
/// `ReaderWebSession` — e a segunda visita a recebe de volta pronta.
///
/// A medição é a única que responde a pergunta: **quantas vezes a imagem foi
/// buscada pela rede**. Um servidor de mentira em `127.0.0.1` conta os pedidos,
/// como o `FakeImapServer` conta os comandos. Nada sai da máquina.
@Suite("A mensagem já lida volta pronta, sem baixar de novo", .serialized)
@MainActor
struct ReaderImageCacheTests {

    /// O par de ligações que o `ReaderHTMLSection` daria ao bloco.
    @MainActor
    final class Caixa {
        var altura: CGFloat = 1
        var pintou = false
    }

    private static func corpo(_ endereco: String, caixa: Caixa) -> ReaderHTMLBody {
        ReaderHTMLBody(
            html: "<p>Promoção</p><img src=\"\(endereco)\" width=\"20\" height=\"20\">",
            permiteRemotas: true,
            fundo: "#ffffff", tinta: "#1a1a1a", link: "#1155cc", fonte: "ui-serif",
            altura: Binding(get: { caixa.altura }, set: { caixa.altura = $0 }),
            pintou: Binding(get: { caixa.pintou }, set: { caixa.pintou = $0 })
        )
    }

    private static func webView() -> WebViewQueNaoRouba {
        WebViewQueNaoRouba(
            frame: NSRect(x: 0, y: 0, width: 500, height: 400),
            configuration: ReaderWebSession.configuracao()
        )
    }

    /// Espera a régua responder — é o mesmo sinal que tira a espera da tela.
    private static func esperaPintar(_ caixa: Caixa) async {
        for _ in 0..<200 where !caixa.pintou {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// **A prova.** A primeira abertura busca a imagem; fechar e reabrir a mesma
    /// mensagem não busca nada.
    ///
    /// Os três passos são os que o `ReaderHTMLBody` dá no `makeNSView`, no
    /// `dismantleNSView` e no `makeNSView` seguinte — nesta ordem, com os mesmos
    /// métodos.
    @Test("Voltar à mensagem não baixa as imagens de novo")
    func voltarNaoBaixaDeNovo() async throws {
        ReaderWebSession.esvazia()
        let servidor = try ServidorDeImagem()
        defer { servidor.para() }

        // Primeira abertura.
        let caixa = Caixa()
        let corpo = Self.corpo(servidor.endereco, caixa: caixa)
        let coordenador = corpo.makeCoordinator()
        let web = Self.webView()
        web.navigationDelegate = coordenador
        coordenador.carrega(em: web)
        await Self.esperaPintar(caixa)
        #expect(caixa.pintou, "a régua não respondeu — o resto do teste não mede nada")
        #expect(servidor.pedidos == 1, "a primeira abertura tem de buscar a imagem")

        // Sair da mensagem.
        coordenador.guarda(web)
        #expect(ReaderWebSession.guardadas == 1)

        // Voltar a ela.
        let caixaDeVolta = Caixa()
        let corpoDeVolta = Self.corpo(servidor.endereco, caixa: caixaDeVolta)
        let segundo = corpoDeVolta.makeCoordinator()
        let guardada = try #require(
            ReaderWebSession.retira(segundo.assinatura(de: corpoDeVolta)),
            "a página não ficou guardada — a volta vai baixar tudo de novo"
        )
        segundo.reaproveita(guardada)
        segundo.carrega(em: guardada.view)
        try? await Task.sleep(for: .milliseconds(400))

        #expect(
            servidor.pedidos == 1,
            "voltar à mensagem baixou a imagem outra vez — os trinta segundos do dono"
        )
        // E ela volta **pronta**: sem espera na tela e na altura em que ficou.
        #expect(caixaDeVolta.pintou)
        #expect(caixaDeVolta.altura > 1)
    }

    /// **A mutação, medida.** É o caminho de antes: a página não é guardada, e a
    /// segunda abertura carrega do zero. Se este teste passar a contar 1, é
    /// porque o servidor deixou de contar — e aí o de cima não prova nada.
    @Test("Sem guardar a página — o código de antes — a imagem desce duas vezes")
    func semGuardarBaixaDeNovo() async throws {
        ReaderWebSession.esvazia()
        let servidor = try ServidorDeImagem()
        defer { servidor.para() }

        for _ in 0..<2 {
            let caixa = Caixa()
            let corpo = Self.corpo(servidor.endereco, caixa: caixa)
            let coordenador = corpo.makeCoordinator()
            let web = Self.webView()
            web.navigationDelegate = coordenador
            coordenador.carrega(em: web)
            await Self.esperaPintar(caixa)
        }
        #expect(servidor.pedidos == 2)
    }

    /// O acervo tem teto: guardar tudo o que foi aberto numa manhã trocaria a
    /// espera por memória sem fim.
    @Test("O acervo não cresce sem limite")
    func acervoTemTeto() {
        ReaderWebSession.esvazia()
        for indice in 0...(ReaderWebSession.limite + 3) {
            ReaderWebSession.guarda(.init(
                assinatura: "m\(indice)", view: Self.webView(), altura: 100
            ))
        }
        #expect(ReaderWebSession.guardadas == ReaderWebSession.limite)
        // O que caiu foi o mais antigo, não o mais recente.
        #expect(ReaderWebSession.retira("m0") == nil)
        #expect(ReaderWebSession.retira("m\(ReaderWebSession.limite + 3)") != nil)
        ReaderWebSession.esvazia()
    }

    /// A sessão é **de memória**, e continua sendo: nada do remetente sobrevive
    /// ao app fechar — ver `ReaderWebSession`.
    @Test("A sessão do leitor não persiste em disco")
    func sessaoNaoPersiste() {
        #expect(!ReaderWebSession.dados.isPersistent)
        // Um armazenamento só para todas as `WebView` do leitor…
        #expect(ReaderWebSession.configuracao().websiteDataStore
            === ReaderWebSession.configuracao().websiteDataStore)
        // …e o resto da configuração novo a cada uma: a lista que bloqueia
        // imagem remota mora aí, e compartilhá-la faria o "Carregar" de uma
        // mensagem valer para a seguinte.
        #expect(ReaderWebSession.configuracao().userContentController
            !== ReaderWebSession.configuracao().userContentController)
    }
}
