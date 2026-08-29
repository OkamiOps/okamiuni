import AppKit
import Foundation
import Testing
import UNIDesign
import WebKit
@testable import UNIShell

/// O email cabe, ou é cortado.
///
/// **O defeito.** O dono pôs o Gmail e o OkamiUNI lado a lado com a mesma
/// mensagem de marketing ("Quem Disse, Berenice?"): no Gmail o corpo de 600
/// pontos aparecia inteiro; aqui a borda direita estava decepada — "Olá, Marcos"
/// virava "Olá", e "faz parte do Beautybox, o maior programa de fidelidade"
/// virava três pedaços com o fim comido. O email traz o próprio layout (tabela
/// de largura fixa), o painel é mais estreito, e `overflow: hidden` transforma
/// a diferença em corte em vez de rolagem.
///
/// **Como isto é medido.** Uma `WKWebView` fora da tela, montada com a mesma
/// folha de estilo que o leitor monta, e as perguntas feitas ao próprio motor de
/// desenho: onde termina a célula de 640 pontos, e onde termina a área visível.
/// Nenhuma janela aparece, nada toca mouse nem teclado, e o documento é `data:`
/// puro — nenhum byte sai pela rede.
@Suite("O email cabe no painel — sem corte e sem rolagem lateral")
@MainActor
struct ReaderWebFitTests {

    // MARK: A régua, pura

    @Test("Conteúdo mais largo que o painel encolhe na razão exata")
    func escalaDoQueNaoCabe() {
        // 640 de conteúdo num painel de 500: 0,78125.
        #expect(abs(ReaderHTMLPolicy.escala(painel: 500, conteudo: 640) - 0.78125) < 0.0001)
        #expect(abs(ReaderHTMLPolicy.escala(painel: 300, conteudo: 600) - 0.5) < 0.0001)
    }

    @Test("Conteúdo que já cabe não é mexido — e nunca é aumentado")
    func naoAumenta() {
        #expect(ReaderHTMLPolicy.escala(painel: 900, conteudo: 640) == 1)
        #expect(ReaderHTMLPolicy.escala(painel: 640, conteudo: 640) == 1)
        // Painel ainda sem layout: não há régua, e encolher contra zero daria
        // uma escala zero — a mensagem sumiria.
        #expect(ReaderHTMLPolicy.escala(painel: 0, conteudo: 640) == 1)
        #expect(ReaderHTMLPolicy.escala(painel: 500, conteudo: 0) == 1)
    }

    @Test("Há um piso: ilegível não é melhor do que cortado")
    func piso() {
        #expect(ReaderHTMLPolicy.escala(painel: 100, conteudo: 4000)
            == ReaderHTMLPolicy.escalaMinima)
    }

    /// A altura vem do documento em pixels de CSS. Com a régua encolhida, um
    /// pixel de CSS deixa de valer um ponto — usar o número cru deixaria uma
    /// tira de vazio embaixo de toda newsletter, do tamanho do que foi
    /// encolhido.
    @Test("A altura da WebView acompanha a escala")
    func alturaEmPontos() {
        #expect(ReaderHTMLPolicy.altura(documento: 800, escala: 0.5) == 400)
        #expect(ReaderHTMLPolicy.altura(documento: 800, escala: 1) == 800)
        #expect(ReaderHTMLPolicy.altura(documento: 0, escala: 1) == 1)
    }

    // MARK: O motor de desenho, de verdade

    /// O email de marketing do dono, reduzido ao que importa: uma tabela de 640
    /// pontos de largura fixa, com a frase inteira dentro dela.
    private static let marketing = """
        <table bgcolor="#f6f6f6" width="640" cellpadding="0" cellspacing="0" align="center">
        <tr><td id="alvo" width="640" style="width:640px;padding:20px;font-size:16px">
        Olá, Marcos — você faz parte do Beautybox, o maior programa de fidelidade
        de beleza do Brasil.
        </td></tr></table>
        """

    private static func documento() -> String {
        ReaderHTMLPolicy.documento(
            html: marketing, fundo: "#ffffff", tinta: "#1a1a1a",
            link: "#1155cc", fonte: "ui-serif, Georgia, serif"
        )
    }

    /// **Sem o ajuste, a célula de 640 termina fora da área visível de 500** —
    /// e o que passa da borda é cortado, porque a folha declara
    /// `overflow: hidden`. É a medição do defeito.
    @Test("Sem o ajuste, a tabela de 640 estoura o painel de 500")
    func semAjusteCorta() async throws {
        let sonda = SondaDeWebView(largura: 500)
        await sonda.carrega(Self.documento())

        let visivel = try #require(await sonda.numero("document.documentElement.clientWidth"))
        let fimDaCelula = try #require(
            await sonda.numero("document.getElementById('alvo').getBoundingClientRect().right")
        )
        #expect(visivel == 500)
        #expect(fimDaCelula > visivel)
    }

    /// E com o ajuste que o leitor aplica — a mesma conta, a mesma propriedade —
    /// a célula inteira passa a caber. Nada é cortado e não há barra lateral.
    @Test("Com o ajuste, a tabela de 640 cabe inteira no painel de 500")
    func comAjusteCabe() async throws {
        let sonda = SondaDeWebView(largura: 500)
        await sonda.carrega(Self.documento())

        let conteudo = try #require(await sonda.numero("document.body.scrollWidth"))
        #expect(conteudo == 640)
        sonda.web.pageZoom = ReaderHTMLPolicy.escala(painel: 500, conteudo: conteudo)

        let visivel = try #require(await sonda.numero("document.documentElement.clientWidth"))
        let fimDaCelula = try #require(
            await sonda.numero("document.getElementById('alvo').getBoundingClientRect().right")
        )
        // A régua passou a medir 640 de CSS na mesma largura de 500 pontos: a
        // célula termina exatamente na borda, e nada fica de fora.
        #expect(fimDaCelula <= visivel)
        // E o documento não sobra para o lado: sem rolagem lateral, como o
        // leitor promete.
        let sobra = try #require(await sonda.numero("document.body.scrollWidth"))
        #expect(sobra <= visivel)
    }

    /// **Encolher, e não espremer.** A tabela de 640 do remetente sai da folha
    /// de estilo do leitor com os 640 dela — e é por ela medir 640 que existe
    /// algo a encolher. Se um dia a folha passar a espremê-la, o documento
    /// inteiro passará a "caber" sem ninguém encolher nada, e o corte volta
    /// pelas células de largura fixa lá dentro.
    @Test("A tabela do remetente mantém a largura dela — quem encolhe é a régua")
    func naoEspreme() async throws {
        let fluida = """
            <table width="640" cellpadding="0" cellspacing="0" align="center">
            <tr><td>Olá, Marcos</td><td>Beautybox</td></tr></table>
            """
        let sonda = SondaDeWebView(largura: 500)
        await sonda.carrega(ReaderHTMLPolicy.documento(
            html: fluida, fundo: "#ffffff", tinta: "#1a1a1a",
            link: "#1155cc", fonte: "ui-serif, Georgia, serif"
        ))
        // 640, e não 500: a tabela não foi espremida — e é por ela medir 640
        // que existe algo a encolher.
        #expect(await sonda.numero("document.body.scrollWidth") == 640)
    }

    // MARK: A coluna de leitura

    /// **O email escrito à mão ganha a coluna do protótipo; o desenhado, não.**
    ///
    /// Texto corrido atravessando 700 pontos de painel é a linha que o
    /// protótipo recusa com `max-width: 64ch` no parágrafo — o olho perde o
    /// começo da linha seguinte. Já a newsletter traz a própria largura,
    /// centrada, e espremê-la numa coluna quebraria o desenho do remetente.
    @Test("O email sem desenho próprio lê numa coluna; o desenhado fica inteiro")
    func colunaDeLeitura() async throws {
        let sonda = SondaDeWebView(largura: 900)
        await sonda.carrega(ReaderHTMLPolicy.documento(
            html: "<p>Bom dia, Marcos. Segue o combinado de ontem.</p>",
            fundo: "#ffffff", tinta: "#1a1a1a", link: "#1155cc", fonte: "ui-serif"
        ))
        #expect(await sonda.numero("document.body.getBoundingClientRect().width")
            == ReaderPane.readingWidth)

        let desenhado = SondaDeWebView(largura: 900)
        await desenhado.carrega(ReaderHTMLPolicy.documento(
            html: "<table bgcolor=\"#fff\" width=\"640\"><tr><td>Promoção</td></tr></table>",
            fundo: "#ffffff", tinta: "#1a1a1a", link: "#1155cc", fonte: "ui-serif"
        ))
        #expect(await desenhado.numero("document.body.getBoundingClientRect().width") == 900)
    }

    /// A régua do app não pode depender de um interruptor que está desligado: a
    /// `WebView` do leitor recusa o script **da mensagem**, e é o app que
    /// pergunta a altura. Verificado na prática, e não deduzido do nome da
    /// propriedade.
    @Test("Com o script da mensagem desligado, o app ainda consegue medir")
    func appMedeMesmoComScriptDesligado() async throws {
        let sonda = SondaDeWebView(largura: 500)
        await sonda.carrega(Self.documento())
        let altura = try #require(await sonda.numero("document.documentElement.scrollHeight"))
        #expect(altura > 0)
    }
}

/// Uma `WKWebView` fora da tela, montada como a do leitor.
///
/// Sem janela, sem foco, sem ponteiro — a mesma promessa do `Render`. E sem
/// rede: `websiteDataStore` não persistente e documento `data:`; uma rota
/// externa não teria como sair daqui.
@MainActor
final class SondaDeWebView: NSObject, WKNavigationDelegate {
    let web: WKWebView
    private var terminou: CheckedContinuation<Void, Never>?

    init(largura: CGFloat) {
        let configuracao = WKWebViewConfiguration()
        configuracao.defaultWebpagePreferences.allowsContentJavaScript = false
        configuracao.websiteDataStore = .nonPersistent()
        web = WKWebView(
            frame: NSRect(x: 0, y: 0, width: largura, height: 1),
            configuration: configuracao
        )
        super.init()
        web.navigationDelegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        terminou?.resume()
        terminou = nil
    }

    func carrega(_ html: String) async {
        await withCheckedContinuation { (continuacao: CheckedContinuation<Void, Never>) in
            terminou = continuacao
            web.loadHTMLString(html, baseURL: nil)
        }
    }

    func numero(_ script: String) async -> CGFloat? {
        await withCheckedContinuation { continuacao in
            web.evaluateJavaScript(script) { valor, _ in
                continuacao.resume(returning: valor as? CGFloat)
            }
        }
    }
}
