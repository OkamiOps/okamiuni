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

    /// O email de notificação do GitHub Actions, reduzido ao que o dono viu:
    /// uma tabela fluida (`width=100%`) com colunas Status / Job / Annotations,
    /// o nome longo do job, e o rodapé depois. Com a folha antiga, "Status"
    /// pintava letra a letra e o rodapé sumia — o Gmail desenhava as três
    /// colunas numa linha só.
    private static let githubActions = """
        <table width="100%" cellpadding="0" cellspacing="0">
        <tr><td>
        <table id="jobs" width="100%" cellpadding="8" cellspacing="0" border="1">
        <tr>
        <td id="status" style="font-weight:bold">Status</td>
        <td id="job" style="font-weight:bold">Job</td>
        <td id="ann" style="font-weight:bold">Annotations</td>
        </tr>
        <tr>
        <td>●</td>
        <td>Quality gate / Application and workflow Failed in 1 minute and 16 seconds</td>
        <td>3</td>
        </tr>
        </table>
        <p id="footer">You are receiving this because you are subscribed to this thread.</p>
        <p>GitHub, Inc. · 88 Colin P Kelly Jr Street · San Francisco, CA 94107</p>
        </td></tr></table>
        """

    @Test("A coluna Status de uma tabela fluida cabe numa linha, como no Gmail")
    func tabelaFluidaNaoPartePalavra() async throws {
        let sonda = SondaDeWebView(largura: 500)
        await sonda.carrega(ReaderHTMLPolicy.documento(
            html: Self.githubActions, fundo: "#ffffff", tinta: "#1a1a1a",
            link: "#1155cc", fonte: "-apple-system, BlinkMacSystemFont, sans-serif"
        ))

        let larguraDoStatus = try #require(
            await sonda.numero("document.getElementById('status').getBoundingClientRect().width")
        )
        let alturaDoStatus = try #require(
            await sonda.numero("document.getElementById('status').getBoundingClientRect().height")
        )
        // Uma letra de 16px cabe em ~12pt; "Status" numa linha precisa de ~50.
        // A queixa era largura de um caractere e altura de seis linhas.
        #expect(larguraDoStatus > 40, "Status mediu \(larguraDoStatus)pt — coluna espremida")
        #expect(alturaDoStatus < 40, "Status mediu \(alturaDoStatus)pt de altura — partiu letra a letra")

        let alturaDoRodape = try #require(
            await sonda.numero("document.getElementById('footer').getBoundingClientRect().height")
        )
        #expect(alturaDoRodape > 8, "o rodapé colapsou — \(alturaDoRodape)pt")
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

    // MARK: O body que declara a própria altura

    /// O email de marketing do dono (Kickstargogo), reduzido ao que importa: um
    /// `<body>` com `height: 100% !important` **na linha**, e o conteúdo inteiro
    /// em tabela — mais o pré-cabeçalho escondido que é praxe do gênero.
    ///
    /// Os 44 mil bytes do original não cabem aqui e não fazem falta: o que
    /// derruba a medição são estes dois atributos.
    private static let bodyDeCemPorCento = """
        <html><head><style>.cabecalho { color: #333; }</style></head>
        <body topmargin="0" leftmargin="0" style="height: 100% !important; margin: 0; \
        padding: 0; width: 100% !important; min-width: 100%;">
        <div id="pre" style="display:none">Sua recompensa está esperando</div>
        <table width="640" cellpadding="0" cellspacing="0" align="center" bgcolor="#f6f6f6">
        <tr><td id="alvo" width="640" style="width:640px;height:900px">Promoção</td></tr>
        </table>
        </body></html>
        """

    /// **O vazio total.** O email chega com `height: 100% !important` no próprio
    /// `<body>`; a `WebView` nasce com um fio de altura (o `@State altura = 1` do
    /// `ReaderHTMLSection`), e "100% de um fio" é um fio. A altura medida sai 1,
    /// a `WebView` fica com 1 ponto, e o email de 900 é uma linha em branco.
    ///
    /// A M3-18 mediu `documentElement.scrollHeight` com um documento **sem**
    /// `height: 100%`, viu o número certo, e concluiu que a medição estava sã.
    /// Este é o documento que ela não usou.
    ///
    /// O documento é servido sem `<!DOCTYPE>` — o `MimeSanitize` o descarta com
    /// as outras declarações —, então o motor desenha em modo de compatibilidade,
    /// onde a porcentagem do `body` resolve contra a área visível. É por isso que
    /// o "100%" vira o tamanho do quadro, e não o tamanho do conteúdo.
    @Test("O body que se declara 100% não colapsa a altura do email")
    func bodyDeCemPorCentoNaoColapsa() async throws {
        let sonda = SondaDeWebView(largura: 500)
        await sonda.carrega(ReaderHTMLPolicy.documento(
            html: Self.bodyDeCemPorCento, fundo: "#ffffff", tinta: "#1a1a1a",
            link: "#1155cc", fonte: "ui-serif"
        ))

        // A armadilha, medida: o quadro tem um fio de altura, e o `body` do
        // remetente encolheu para ele — enquanto a tabela dentro mede 900.
        #expect(await sonda.numero("document.body.getBoundingClientRect().height") == 1)
        #expect(await sonda.numero("document.getElementById('alvo').getBoundingClientRect().bottom")
            == 900)

        // E a régua do leitor, apesar disso, devolve o tamanho do conteúdo.
        let medida = try #require(await sonda.numero(ReaderHTMLPolicy.medidaDaAltura))
        #expect(medida == 900)
    }

    /// O email normal continua medindo o que sempre mediu.
    ///
    /// A mesma pergunta, no documento que a M3-18 usou para se convencer de que
    /// a medição estava sã: 900 pontos de tabela, 900 de resposta.
    @Test("O email sem armadilha mede o mesmo de antes")
    func emailNormalMedeOMesmo() async throws {
        let sonda = SondaDeWebView(largura: 500)
        await sonda.carrega(ReaderHTMLPolicy.documento(
            html: "<table width=\"640\" bgcolor=\"#f6f6f6\"><tr><td style=\"height:900px\">oi</td></tr></table>",
            fundo: "#ffffff", tinta: "#1a1a1a", link: "#1155cc", fonte: "ui-serif"
        ))
        #expect(await sonda.numero("document.documentElement.scrollHeight") == 900)
        #expect(await sonda.numero(ReaderHTMLPolicy.medidaDaAltura) == 900)
    }

    /// **O que estava escondido continua escondido.**
    ///
    /// Todo email de marketing traz um pré-cabeçalho `display: none` — a frase
    /// que o webmail mostra na lista e a mensagem não mostra no corpo. Consertar
    /// o `body` colapsado não pode ser a desculpa para desentortar o resto do
    /// documento: o invólucro do leitor mede, e não repinta.
    @Test("O pré-cabeçalho escondido do marketing não vira texto visível")
    func preCabecalhoContinuaEscondido() async throws {
        let sonda = SondaDeWebView(largura: 500)
        await sonda.carrega(ReaderHTMLPolicy.documento(
            html: Self.bodyDeCemPorCento, fundo: "#ffffff", tinta: "#1a1a1a",
            link: "#1155cc", fonte: "ui-serif"
        ))
        #expect(await sonda.numero(
            "getComputedStyle(document.getElementById('pre')).display === 'none' ? 1 : 0"
        ) == 1)
        #expect(await sonda.numero(
            "document.getElementById('pre').getBoundingClientRect().height"
        ) == 0)
    }

    /// **Medir certo não basta: o conteúdo também não pode ser recortado.**
    ///
    /// O `body` que declara a própria altura — 100% de um quadro de um fio, ou
    /// 600 pontos fixos — deixa a tabela de 900 do lado de fora dele. Com
    /// `overflow: hidden` no `body`, "do lado de fora" quer dizer invisível: a
    /// régua acertaria a altura e a mensagem continuaria em branco. Quem esconde
    /// o que sobra é o `html`, e é lá que a regra mora.
    @Test("O body que declara altura própria não recorta o conteúdo")
    func bodyNaoRecorta() async throws {
        for html in [Self.bodyDeCemPorCento, """
            <body style="height: 600px !important">
            <table width="640"><tr><td style="height:900px">Promoção</td></tr></table></body>
            """] {
            let sonda = SondaDeWebView(largura: 500)
            await sonda.carrega(ReaderHTMLPolicy.documento(
                html: html, fundo: "#ffffff", tinta: "#1a1a1a",
                link: "#1155cc", fonte: "ui-serif"
            ))
            let recorta = try #require(await sonda.numero("""
                (function () {
                  var corpo = document.body;
                  var raiz = document.getElementById('\(ReaderHTMLPolicy.involucro)');
                  var escondido = getComputedStyle(corpo).overflow === 'hidden';
                  var sobra = raiz.getBoundingClientRect().height > corpo.clientHeight;
                  return escondido && sobra ? 1 : 0;
                })()
                """))
            #expect(recorta == 0)
        }
    }

    /// **Só o `html` e o `body` são neutralizados — nunca o conteúdo.**
    ///
    /// O `height: 100%` numa célula interna é como um email legítimo centra o
    /// que está dentro dela, e desmanchá-lo seria trocar um desenho quebrado por
    /// outro. A célula continua com a altura que a linha lhe dá.
    @Test("O height:100% de uma célula interna continua valendo")
    func celulaInternaIntacta() async throws {
        let sonda = SondaDeWebView(largura: 500)
        await sonda.carrega(ReaderHTMLPolicy.documento(
            html: """
                <table width="640" bgcolor="#f6f6f6"><tr>
                <td height="300" style="height:300px">
                <div id="celula" style="height:100%">centro</div>
                </td></tr></table>
                """,
            fundo: "#ffffff", tinta: "#1a1a1a", link: "#1155cc", fonte: "ui-serif"
        ))
        let alturaDaCelula = try #require(await sonda.numero(
            "document.getElementById('celula').getBoundingClientRect().height"
        ))
        // 298 e não 300: a célula tem a folga de um ponto que o motor dá a todo
        // `td`. O que importa é que o `100%` resolveu contra os 300 da célula, e
        // não contra o vazio.
        #expect(alturaDaCelula == 298)
    }

    /// A régua do app não pode depender de um interruptor que está desligado: a
    /// `WebView` do leitor recusa o script **da mensagem**, e é o app que
    /// pergunta a altura. Verificado na prática, e não deduzido do nome da
    /// propriedade.
    /// O email de verificação da Hostinger: um `div` com `display:none
    /// !important` que nunca fecha de verdade (`<="" div="">` no lugar de
    /// `</div>`). O motor esconde logo, título e código; o Gmail mostra. A
    /// recuperação tem de acontecer **antes** de a `WebView` desenhar, porque
    /// a mensagem já está gravada assim no banco.
    private static let preCabecalhoQueEngole = """
        <div style="display:none !important;visibility:hidden;max-height:0px;\
        overflow:hidden;">Confirme sua identidade</div>
        <div style="display:none !important;overflow:hidden;" >\
        \u{034F}="" \u{FEFF}="" <="" div="">
        <table class="nl-container" width="600" bgcolor="#ffffff">
        <tr><td id="codigo" style="font-size:32px;color:#673de6;text-align:center">\
        <b>615211</b></td></tr>
        </table>
        """

    @Test("O pré-cabeçalho escondido quebrado não engole o código da Hostinger")
    func preCabecalhoQuebradoNaoEngole() async throws {
        let sonda = SondaDeWebView(largura: 500)
        await sonda.carrega(ReaderHTMLPolicy.documento(
            html: Self.preCabecalhoQueEngole, fundo: "#ffffff", tinta: "#1a1a1a",
            link: "#1155cc", fonte: "ui-serif"
        ))
        let visivel = try #require(await sonda.numero("""
            (function () {
              var el = document.getElementById('codigo');
              if (!el) { return 0; }
              var r = el.getBoundingClientRect();
              return (r.height > 0 && r.width > 0) ? 1 : 0;
            })()
            """))
        #expect(visivel == 1)
        let medida = try #require(await sonda.numero(ReaderHTMLPolicy.medidaDaAltura))
        #expect(medida > 20)
    }

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

    init(largura: CGFloat, configuracao: WKWebViewConfiguration? = nil) {
        let escolhida: WKWebViewConfiguration = configuracao ?? {
            let nova = WKWebViewConfiguration()
            nova.defaultWebpagePreferences.allowsContentJavaScript = false
            nova.websiteDataStore = .nonPersistent()
            return nova
        }()
        web = WKWebView(
            frame: NSRect(x: 0, y: 0, width: largura, height: 1),
            configuration: escolhida
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
