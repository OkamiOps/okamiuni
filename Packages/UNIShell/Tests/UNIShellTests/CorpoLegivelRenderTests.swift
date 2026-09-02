import AppKit
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// As três capturas da caixa real, reproduzidas como fixtures.
///
/// Não são exemplos inventados: são os emails que o dono fotografou quando
/// disse que a prévia estava "muito mal formatada". Cada um cobra uma das
/// regras — dobra do histórico, campos alinhados, lista com link.
enum CapturasDaCaixa {

    /// Captura 3 — o conteúdo novo é uma linha; o resto é histórico citado.
    static let cadeia: [String] = [
        """
        Love the site!

        On Mon, Aug 25, 2026 at 9:41 AM Marina Álvares <marina@exemplo.com> wrote:
        \((1...38).map { "> Linha \($0) do histórico citado desta conversa longa." }
            .joined(separator: "\n"))
        """
    ]

    /// Captura 2 — o formulário do site, chave e valor.
    static let formulario: [String] = [
        """
        Nova resposta no formulário do site.

        Nome: Maria Exemplo
        E-mail: maria@exemplo.com
        Mensagem: Gostaria de um orçamento para o projeto de identidade visual.
        Recebido em: 25/08/2026 09:41
        """
    ]

    /// Captura 2, como ela chega de verdade: tabela HTML.
    static let formularioHTML = """
        <p>Nova resposta no formulário do site.</p>
        <table>
          <tr><td>Nome</td><td>Maria Exemplo</td></tr>
          <tr><td>E-mail</td><td>maria@exemplo.com</td></tr>
          <tr><td>Mensagem</td><td>Gostaria de um orçamento para o projeto.</td></tr>
          <tr><td>Recebido em</td><td>25/08/2026 09:41</td></tr>
        </table>
        """

    /// Captura 1 — a newsletter da Resend, com as três dicas e a URL crua.
    static let newsletter: [String] = [
        """
        Welcome to Resend.

        Here are 3 tips to get started:
        1. Send your first email https://resend.com/onboarding
        2. Verify your domain https://resend.com/domains
        3. Read the docs https://resend.com/docs

        Você recebeu este email porque criou uma conta na Resend.
        Para não receber mais, cancele a inscrição.
        2261 Market Street, San Francisco, CA 94114
        """
    ]

    static func mensagem(
        id: String, corpo: [String], html: String? = nil, resumo: String? = nil
    ) -> Message {
        Message(
            id: id, accountID: "zoho",
            from: Contact(name: "Marina Álvares", address: "marina@exemplo.com"),
            receivedAt: Date(timeIntervalSince1970: 1_756_120_860),
            subject: "Assunto do email", snippet: "Trecho", body: corpo,
            tags: [], bucket: .today, isRead: false,
            summary: resumo, detectedEvent: nil, bodyHTML: html
        )
    }
}

@Suite("A prévia estruturada")
@MainActor
struct CorpoLegivelRenderTests {

    // MARK: O resumo no topo

    @Test("a prévia abre com o resumo quando a análise já rodou")
    func resumoQuandoExiste() {
        let estado = DashboardPreviewBody.state(
            for: CapturasDaCaixa.mensagem(
                id: "m1", corpo: CapturasDaCaixa.cadeia,
                resumo: "Marina elogiou o site e não pediu nada."
            ),
            load: nil
        )
        #expect(estado.resumo == "Marina elogiou o site e não pediu nada.")
    }

    @Test("sem análise não há bloco de resumo, e nada é inventado")
    func semResumoNaoInventa() {
        let estado = DashboardPreviewBody.state(
            for: CapturasDaCaixa.mensagem(id: "m2", corpo: CapturasDaCaixa.cadeia),
            load: nil
        )
        #expect(estado.resumo == nil)
    }

    @Test("resumo em branco conta como resumo nenhum")
    func resumoEmBrancoNaoConta() {
        let estado = DashboardPreviewBody.state(
            for: CapturasDaCaixa.mensagem(id: "m3", corpo: ["Oi."], resumo: "   \n "),
            load: nil
        )
        #expect(estado.resumo == nil)
    }

    // MARK: A dobra do histórico

    @Test("o controle de histórico existe com citação e some sem ela")
    func controleDeHistorico() {
        let comCitacao = DashboardPreviewBody.state(
            for: CapturasDaCaixa.mensagem(id: "m4", corpo: CapturasDaCaixa.cadeia), load: nil
        )
        #expect(comCitacao.corpo.dobras.map(\.genero) == [.historico])
        #expect(comCitacao.corpo.dobras.first?.rotulo == "Mostrar histórico · 39 linhas")
        // O que fica visível é uma linha, e não quarenta.
        #expect(comCitacao.corpo.textoVisivel == "Love the site!")

        let semCitacao = DashboardPreviewBody.state(
            for: CapturasDaCaixa.mensagem(id: "m5", corpo: ["Oi, Marcos.", "Tudo certo."]),
            load: nil
        )
        #expect(semCitacao.corpo.dobras.isEmpty)
    }

    @Test("a tabela HTML do formulário chega à prévia como campos, não como texto")
    func formularioHTMLViraCampos() {
        let estado = DashboardPreviewBody.state(
            for: CapturasDaCaixa.mensagem(
                id: "m6", corpo: [], html: CapturasDaCaixa.formularioHTML
            ),
            load: nil
        )
        let campos = estado.corpo.blocos.compactMap { bloco -> Campos? in
            if case let .campos(campos) = bloco { return campos }
            return nil
        }
        #expect(campos.first?.pares.count == 4)
    }

    // MARK: O desenho

    /// A prova de que dobrar **serve para alguma coisa**: a mesma cadeia
    /// desenhada como texto corrido pinta muito mais tinta do que a prévia
    /// estruturada, porque as quarenta linhas de histórico não estão lá.
    @Test("a cadeia dobrada pinta menos tinta do que o mesmo email despejado")
    func aDobraEconomizaTela() throws {
        let tema = Theme.tinta
        let tamanho = CGSize(width: 380, height: 520)
        let corpo = CorpoLegivel.deTextoSimples(CapturasDaCaixa.cadeia[0])

        let estruturada = try #require(
            Render.bitmap(
                CorpoLegivelView(corpo: corpo).frame(maxHeight: .infinity, alignment: .top),
                size: tamanho, theme: tema
            )
        )
        let despejada = try #require(
            Render.bitmap(
                Text(CapturasDaCaixa.cadeia[0])
                    .font(tema.serif.font(size: 13))
                    .foregroundStyle(tema.ink2.color)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading),
                size: tamanho, theme: tema
            )
        )
        #expect(
            estruturada.pixelsDiffering(from: despejada) > 0,
            "a prévia estruturada tem de ser outro desenho"
        )
        #expect(
            tinta(estruturada, fundo: tema.paper) < tinta(despejada, fundo: tema.paper),
            "a dobra existe para tirar o histórico da tela"
        )
    }

    @Test("as três capturas renderizam em okami e em tinta")
    func asTresCapturasRenderizam() throws {
        let casos: [(String, CorpoLegivel)] = [
            ("cadeia", CorpoLegivel.deTextoSimples(CapturasDaCaixa.cadeia[0])),
            ("formulario", CorpoLegivel.deHTML(CapturasDaCaixa.formularioHTML)),
            ("newsletter", CorpoLegivel.deTextoSimples(CapturasDaCaixa.newsletter[0])),
        ]
        for (nome, corpo) in casos {
            for tema in [Theme.okami, Theme.tinta] {
                let sufixo = tema.id == "tinta" ? "-tinta" : ""
                let rep = try #require(
                    Render.snapshot(
                        CorpoLegivelView(corpo: corpo)
                            .padding(16)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .background(tema.paper.color),
                        named: "\(nome)\(sufixo)",
                        size: CGSize(width: 380, height: 520),
                        theme: tema
                    )
                )
                #expect(rep.pixelsWide == 380)
                #expect(tinta(rep, fundo: tema.paper) > 500, "\(nome) \(tema.id) saiu em branco")
            }
        }
    }

    /// Quantos pixels **não** são o fundo — a medida honesta de "quanto texto
    /// tem nesta tela".
    private func tinta(_ rep: NSBitmapImageRep, fundo: TokenColor) -> Int {
        rep.pixelsWide * rep.pixelsHigh - rep.pixels(matching: fundo, tolerance: 0.03)
    }
}
