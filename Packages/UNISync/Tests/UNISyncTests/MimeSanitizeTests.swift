import Foundation
import Testing
@testable import UNISync

/// O HTML de terceiro virando HTML desenhável — e o que ele perde no caminho.
@Suite("MimeSanitize: o HTML do remetente entra, o que ele pode executar não")
struct MimeSanitizeTests {

    // MARK: O que é arrancado

    @Test("O script vai embora com o miolo — não só a etiqueta")
    func scriptSaiInteiro() throws {
        let limpo = try #require(MimeSanitize.sanitize(
            html: "<p>Oi</p><script>alert('x')</script><p>Tchau</p>"
        ))
        #expect(!limpo.contains("script"))
        // O miolo do script não pode virar texto da mensagem: arrancar só a
        // etiqueta despejaria `alert('x')` no leitor.
        #expect(!limpo.contains("alert"))
        #expect(limpo.contains("Oi"))
        #expect(limpo.contains("Tchau"))
    }

    @Test("Iframe, object, embed e os campos de formulário somem")
    func contêineresDeExecucaoSomem() throws {
        let limpo = try #require(MimeSanitize.sanitize(html: """
            <div>Conteúdo</div>
            <iframe src="https://terceiro.example/rastreio"></iframe>
            <object data="https://terceiro.example/x.swf"></object>
            <embed src="https://terceiro.example/y">
            <input type="password" name="senha">
            <button>Entrar</button>
            """))
        for proibida in ["iframe", "object", "embed", "input", "button"] {
            #expect(!limpo.contains("<\(proibida)"), "sobrou <\(proibida)")
        }
        #expect(limpo.contains("Conteúdo"))
    }

    @Test("O form perde a etiqueta e mantém o miolo — a newsletter inteira mora dentro dele")
    func formPerdeSoAEtiqueta() throws {
        let limpo = try #require(MimeSanitize.sanitize(
            html: "<form action=\"https://phish.example\"><p>A mensagem</p></form>"
        ))
        #expect(!limpo.contains("form"))
        #expect(limpo.contains("<p>A mensagem</p>"))
    }

    @Test("Atributo on* não sobrevive")
    func atributosDeEventoSomem() throws {
        let limpo = try #require(MimeSanitize.sanitize(
            html: "<img src=\"https://x.example/a.png\" onerror=\"roubar()\" alt=\"Logo\">"
        ))
        #expect(!limpo.lowercased().contains("onerror"))
        #expect(!limpo.contains("roubar"))
        #expect(limpo.contains("alt=\"Logo\""))
        // O `src` remoto **fica** no documento: quem o barra é a lista de
        // regras da WebView, e barrá-lo aqui apagaria a imagem que a pessoa
        // pode querer carregar depois.
        #expect(limpo.contains("https://x.example/a.png"))
    }

    @Test("javascript: no href sai; https: fica")
    func esquemaExecutavelSai() throws {
        let limpo = try #require(MimeSanitize.sanitize(html: """
            <a href="javascript:alert(1)">Clique</a><a href="https://ok.example">Site</a>
            """))
        #expect(!limpo.contains("javascript:"))
        #expect(limpo.contains("https://ok.example"))
        // O texto do link continua — o que sai é o destino, não a palavra.
        #expect(limpo.contains("Clique"))
    }

    @Test("javascript: escrito com entidade também sai — o motor decodifica, o filtro tem de decodificar junto")
    func esquemaEscondidoEmEntidadeSai() throws {
        let limpo = try #require(MimeSanitize.sanitize(
            html: "<a href=\"&#106;avascript:alert(1)\">x</a>"
        ))
        #expect(!limpo.contains("avascript"))
    }

    @Test("javascript: com espaço e maiúscula no meio também sai")
    func esquemaDisfarcadoSai() throws {
        let limpo = try #require(MimeSanitize.sanitize(
            html: "<a href=\" Java\tScript:alert(1)\">x</a>"
        ))
        #expect(!limpo.lowercased().contains("script:"))
    }

    // MARK: As imagens da própria mensagem

    @Test("cid: vira data: com os bytes que vieram na mensagem")
    func cidViraData() throws {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        let limpo = try #require(MimeSanitize.sanitize(
            html: "<img src=\"cid:logo@okami\">",
            imagens: [.init(contentID: "<logo@okami>", mime: "image/png", dados: bytes)]
        ))
        #expect(limpo.contains("data:image/png;base64,\(bytes.base64EncodedString())"))
        #expect(!limpo.contains("cid:"))
    }

    @Test("cid: sem imagem correspondente vira o vazio de 1×1, nunca uma busca na rede")
    func cidOrfaoViraPlaceholder() throws {
        let limpo = try #require(MimeSanitize.sanitize(html: "<img src=\"cid:sumida@x\">"))
        #expect(limpo.contains(MimeSanitize.placeholder))
        #expect(!limpo.contains("cid:"))
    }

    @Test("A imagem acima do teto por imagem vira o vazio de 1×1")
    func imagemGrandeDemaisViraPlaceholder() {
        let gorda = MimeSanitize.ImagemInline(
            contentID: "a@x", mime: "image/png",
            dados: Data(repeating: 0, count: MimeSanitize.tetoPorImagem + 1)
        )
        #expect(MimeSanitize.embute([gorda])["a@x"] == MimeSanitize.placeholder)

        let cabe = MimeSanitize.ImagemInline(
            contentID: "b@x", mime: "image/png",
            dados: Data(repeating: 0, count: MimeSanitize.tetoPorImagem)
        )
        #expect(MimeSanitize.embute([cabe])["b@x"] != MimeSanitize.placeholder)
    }

    @Test("O orçamento da mensagem é gasto na ordem do documento: a primeira cabe, a última não")
    func tetoPorMensagemGastoEmOrdem() {
        // Cada uma no teto por imagem: quatro enchem o orçamento da mensagem, e
        // a quinta não tem onde caber. Qual delas sobra é decidido pela ordem
        // do documento — a primeira imagem é a que mais importa.
        let quantas = MimeSanitize.tetoPorMensagem / MimeSanitize.tetoPorImagem + 1
        let imagens = (0..<quantas).map { i in
            MimeSanitize.ImagemInline(
                contentID: "i\(i)@x", mime: "image/png",
                dados: Data(repeating: 0, count: MimeSanitize.tetoPorImagem)
            )
        }
        let mapa = MimeSanitize.embute(imagens)
        #expect(mapa["i0@x"] != MimeSanitize.placeholder)
        #expect(mapa["i\(quantas - 1)@x"] == MimeSanitize.placeholder)
    }

    @Test("HTML acima do teto não é truncado: ele não vem")
    func htmlGrandeDemaisNaoVem() {
        let enorme = "<p>" + String(repeating: "a", count: MimeSanitize.tetoDoHTML) + "</p>"
        #expect(MimeSanitize.sanitize(html: enorme) == nil)
    }

    @Test("HTML vazio é ausência, não string vazia")
    func htmlVazioEhNil() {
        #expect(MimeSanitize.sanitize(html: "   \n  ") == nil)
        #expect(MimeSanitize.sanitize(html: "<script>só isto</script>") == nil)
    }

    // MARK: O que fica

    @Test("O <style> fica — é ele que faz o email do provedor parecer o email do provedor")
    func styleFica() throws {
        let limpo = try #require(MimeSanitize.sanitize(
            html: "<style>.a{color:red}</style><p class=\"a\">Oi</p>"
        ))
        #expect(limpo.contains("<style>"))
        #expect(limpo.contains("color:red"))
        #expect(limpo.contains("class=\"a\""))
    }

    @Test("Atributo sem aspas e atributo sem valor sobrevivem à remontagem")
    func atributosMalEscritosSobrevivem() {
        let pares = MimeSanitize.atributos(de: "td width=100 align='center' nowrap")
        #expect(pares.count == 3)
        #expect(pares[0].0 == "width" && pares[0].1 == "100")
        #expect(pares[1].1 == "center")
        #expect(pares[2].0 == "nowrap")
    }
}
