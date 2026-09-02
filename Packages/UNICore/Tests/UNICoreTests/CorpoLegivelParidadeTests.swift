import Foundation
import Testing
@testable import UNICore

/// O email de boas-vindas da Resend, nos **dois** formatos em que ele chega.
///
/// O HTML é o que a Resend manda de verdade: react-email, tabela por fora e
/// todo o conteúdo dentro de uma única `<td>`. Foi essa casca que quebrou a
/// leitura — e é por isso que a fixture a tem.
enum EmailsDaCaixa {

    static let resendHTML = """
        <html><body>
        <table width="100%" cellpadding="0" cellspacing="0"><tbody>
        <tr><td style="padding:24px">
          <p>Hey,</p>
          <p>My name is Zeno &mdash; I'm the founder and CEO of Resend.</p>
          <p>We started Resend because we wanted a better email API for developers.<br>
             A simple, fast, and elegant interface that just works.</p>
          <p>Here are 3 tips to get started.</p>
          <ol>
            <li><a href="https://resend.com/onboarding">Send your first email</a></li>
            <li><a href="https://resend.com/domains">Add your domain</a></li>
            <li><a href="https://resend.com/docs">Check the docs</a></li>
          </ol>
          <p>P.S.: Why did you sign up?</p>
        </td></tr>
        </tbody></table>
        </body></html>
        """

    static let resendTexto = """
        Hey,

        My name is Zeno — I'm the founder and CEO of Resend.

        We started Resend because we wanted a better email API for developers.
        A simple, fast, and elegant interface that just works.

        Here are 3 tips to get started.

        1. Send your first email https://resend.com/onboarding
        2. Add your domain https://resend.com/domains
        3. Check the docs https://resend.com/docs

        P.S.: Why did you sign up?
        """

    /// O formulário do site Vantion: dois fragmentos que só repetem o assunto,
    /// a tabela, e o nome da empresa solto no fim.
    static let vantionHTML = """
        <div>Nova resposta</div>
        <div>Teste de configuração</div>
        <table>
          <tr><td>Nome</td><td>Maria Exemplo</td></tr>
          <tr><td>E-mail</td><td>maria@exemplo.com</td></tr>
          <tr><td>Mensagem</td><td>Gostaria de um orçamento para o projeto.</td></tr>
          <tr><td>Recebido em</td><td>25/08/2026 09:41</td></tr>
        </table>
        <div>Cartões Digitais Vantion</div>
        """

    static let vantionAssunto = "Nova resposta: Teste de configuração"
}

extension BlocoDeCorpo {
    /// Só a **forma** do bloco, para comparar dois caminhos sem comparar texto.
    var forma: String {
        switch self {
        case let .paragrafo(p): "paragrafo(\(p.nivel))"
        case let .lista(l): "lista(\(l.ordenada ? "ordenada" : "marcada"), \(l.itens.count))"
        case let .campos(c): "campos(\(c.pares.count))"
        case let .dobra(d): "dobra(\(d.genero))"
        }
    }

    var listaDentro: Lista? {
        if case let .lista(l) = self { return l }
        return nil
    }
}

@Suite("HTML e texto puro leem o mesmo email")
struct CorpoLegivelParidadeTests {

    @Test("o email da Resend produz a mesma estrutura nos dois formatos")
    func resendParidade() throws {
        let porHTML = CorpoLegivel.deHTML(EmailsDaCaixa.resendHTML)
        let porTexto = CorpoLegivel.deTextoSimples(EmailsDaCaixa.resendTexto)

        #expect(
            porHTML.blocos.map(\.forma) == porTexto.blocos.map(\.forma),
            "HTML: \(porHTML.blocos.map(\.forma))\ntexto: \(porTexto.blocos.map(\.forma))"
        )

        let listaHTML = try #require(porHTML.blocos.compactMap(\.listaDentro).first)
        let listaTexto = try #require(porTexto.blocos.compactMap(\.listaDentro).first)
        #expect(listaHTML.itens.count == 3)
        #expect(listaHTML.itens.map(\.marcador) == listaTexto.itens.map(\.marcador))
        #expect(listaHTML.itens.map(\.marcador) == ["1.", "2.", "3."])

        // Os três destinos, um por item, nos dois caminhos.
        func destinos(_ lista: Lista) -> [String] {
            lista.itens.map { item in
                item.trechos.compactMap(\.destino).map(\.absoluteString).joined(separator: ",")
            }
        }
        #expect(destinos(listaHTML) == destinos(listaTexto))
        #expect(destinos(listaHTML).count == Set(destinos(listaHTML)).count)
    }

    @Test("nenhuma palavra cola no caminho de HTML")
    func nadaCola() {
        let visivel = CorpoLegivel.deHTML(EmailsDaCaixa.resendHTML).textoVisivel
        for colada in ["Hey,My", "Resend.We", "works.Here", "emailAdd", "domainCheck", "docsP.S."] {
            #expect(!visivel.contains(colada), "colou: \(colada) em \(visivel)")
        }
        #expect(visivel.contains("Send your first email"))
        #expect(visivel.contains("Check the docs"))
    }

    @Test("fim de bloco dentro de uma célula encerra a linha")
    func fimDeBlocoDentroDeCelula() {
        let corpo = CorpoLegivel.deHTML("<table><tr><td><p>Um</p><p>Dois</p></td></tr></table>")
        #expect(corpo.blocos.map(\.forma) == ["paragrafo(0)", "paragrafo(0)"])
        #expect(corpo.textoVisivel == "Um\n\nDois")
    }

    @Test("dois links seguidos não viram uma palavra só")
    func linksNaoColam() {
        let corpo = CorpoLegivel.deHTML(
            """
            <table><tr><td>
              <div><a href="https://a.exemplo.com/x">Enviar</a></div>
              <div><a href="https://b.exemplo.com/y">Domínio</a></div>
            </td></tr></table>
            """
        )
        #expect(!corpo.textoVisivel.contains("EnviarDomínio"))
        #expect(corpo.blocos.count == 2)
    }

    @Test("uma lista dentro de célula continua sendo lista")
    func listaDentroDeCelula() throws {
        let corpo = CorpoLegivel.deHTML(
            "<table><tr><td><ul><li>Um</li><li>Dois</li></ul></td></tr></table>"
        )
        let lista = try #require(corpo.blocos.compactMap(\.listaDentro).first)
        #expect(lista.itens.count == 2)
    }

    @Test("a tabela de duas colunas continua virando campos")
    func tabelaContinuaCampo() {
        let corpo = CorpoLegivel.deHTML(EmailsDaCaixa.vantionHTML)
        #expect(corpo.blocos.contains { $0.forma == "campos(4)" })
    }
}

@Suite("Fragmentos órfãos")
struct CorpoLegivelFragmentosTests {

    @Test("linha curta que só repete o assunto não vira parágrafo")
    func repeticaoDoAssuntoSai() {
        let corpo = CorpoLegivel.de(
            texto: "", html: EmailsDaCaixa.vantionHTML, assunto: EmailsDaCaixa.vantionAssunto
        )
        #expect(!corpo.textoVisivel.contains("Nova resposta"))
        #expect(!corpo.textoVisivel.contains("Teste de configuração"))
    }

    @Test("sem assunto nada é removido — a regra não adivinha")
    func semAssuntoNadaSai() {
        let corpo = CorpoLegivel.de(texto: "", html: EmailsDaCaixa.vantionHTML)
        #expect(corpo.textoVisivel.contains("Nova resposta"))
    }

    @Test("nome de empresa isolado no fim vai para a dobra de rodapé")
    func empresaNoFimDobra() throws {
        let corpo = CorpoLegivel.de(
            texto: "", html: EmailsDaCaixa.vantionHTML, assunto: EmailsDaCaixa.vantionAssunto
        )
        let dobra = try #require(corpo.dobras.first)
        #expect(dobra.genero == .rodape)
        #expect(dobra.texto.contains("Cartões Digitais Vantion"))
        #expect(!corpo.textoVisivel.contains("Cartões Digitais Vantion"))
    }

    @Test("um email de uma linha só não é engolido pela regra do rodapé")
    func umaLinhaSoFica() {
        let corpo = CorpoLegivel.de(texto: "Obrigado", html: nil, assunto: "Obrigado")
        #expect(corpo.textoVisivel == "Obrigado")
        #expect(corpo.dobras.isEmpty)
    }
}
