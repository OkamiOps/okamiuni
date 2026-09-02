import Foundation
import Testing
@testable import UNICore

/// O analisador que fatia um corpo de email em blocos.
///
/// Cada teste aqui é uma das três capturas que motivaram a peça — a cadeia
/// citada de quarenta linhas, o formulário chave-valor e a newsletter com URL
/// crua no meio da frase — mais os casos de borda que fariam o analisador
/// estragar um email que já estava bom.
@Suite("Corpo legível")
struct CorpoLegivelTests {

    // MARK: - Captura 3: a cadeia de resposta

    @Test("o novo é uma linha, e as quarenta de histórico viram uma dobra")
    func aCadeiaDobra() {
        let historico = (1...38).map { "> linha \($0) do histórico" }.joined(separator: "\n")
        let corpo = CorpoLegivel.deTextoSimples(
            """
            Love the site!

            On Mon, Aug 25, 2026 at 9:41 AM Marina <marina@x.com> wrote:
            \(historico)
            """
        )
        #expect(corpo.blocos.count == 2)
        #expect(corpo.textoVisivel == "Love the site!")
        guard case let .dobra(dobra) = corpo.blocos[1] else {
            Issue.record("o segundo bloco tinha de ser a dobra do histórico")
            return
        }
        #expect(dobra.genero == .historico)
        // A linha "On … wrote:" entra na dobra: ela é cabeçalho do que foi
        // citado, não conteúdo novo.
        #expect(dobra.linhas == 39)
        #expect(dobra.rotulo == "Mostrar histórico · 39 linhas")
    }

    @Test("o cabeçalho de citação em português também abre a dobra")
    func cabecalhoEmPortugues() {
        let corpo = CorpoLegivel.deTextoSimples(
            """
            Fechado, pode marcar.

            Em 25 de agosto de 2026 09:41, Marina <marina@x.com> escreveu:
            > E aí, confirma?
            """
        )
        #expect(corpo.textoVisivel == "Fechado, pode marcar.")
        #expect(corpo.dobras.map(\.genero) == [.historico])
    }

    @Test("o separador -----Original Message----- abre a dobra")
    func separadorDeMensagemOriginal() {
        let corpo = CorpoLegivel.deTextoSimples(
            """
            Segue em anexo.

            -----Original Message-----
            From: Marina
            Subject: Contrato
            """
        )
        #expect(corpo.textoVisivel == "Segue em anexo.")
        #expect(corpo.dobras.map(\.genero) == [.historico])
    }

    @Test("citação sem cabeçalho nenhum: o `>` sozinho basta")
    func citacaoCrua() {
        let corpo = CorpoLegivel.deTextoSimples(
            """
            Pode ser.

            > Você consegue amanhã?
            >> Consigo sim.
            """
        )
        #expect(corpo.textoVisivel == "Pode ser.")
        #expect(corpo.dobras.first?.linhas == 2)
    }

    // MARK: - Assinatura e rodapé

    @Test("a assinatura depois de `-- ` dobra, e não some")
    func assinaturaDobra() {
        let corpo = CorpoLegivel.deTextoSimples(
            """
            Abraço.

            --␠
            Marina Álvares
            Diretora de Produto
            +55 11 90000-0000
            """.replacingOccurrences(of: "␠", with: " ")
        )
        #expect(corpo.textoVisivel == "Abraço.")
        let dobra = corpo.dobras.first
        #expect(dobra?.genero == .assinatura)
        #expect(dobra?.rotulo == "Mostrar assinatura · 4 linhas")
        #expect(dobra?.texto.contains("Marina Álvares") == true)
    }

    @Test("o rodapé de descadastro da newsletter entra na mesma dobra")
    func rodapeDobra() {
        let corpo = CorpoLegivel.deTextoSimples(
            """
            Bem-vindo à Resend.

            Você recebeu este email porque criou uma conta na Resend.
            Para não receber mais, cancele a inscrição.
            2261 Market Street, San Francisco, CA
            """
        )
        #expect(corpo.textoVisivel == "Bem-vindo à Resend.")
        #expect(corpo.dobras.map(\.genero) == [.rodape])
        #expect(corpo.dobras.first?.rotulo == "Mostrar rodapé · 3 linhas")
    }

    @Test("assinatura e histórico são duas dobras, na ordem em que aparecem")
    func duasDobras() {
        let corpo = CorpoLegivel.deTextoSimples(
            """
            Combinado.

            --␠
            Marina

            On Mon, Aug 25, 2026 at 9:41 AM Ana <ana@x.com> wrote:
            > E aí?
            """.replacingOccurrences(of: "␠", with: " ")
        )
        #expect(corpo.dobras.map(\.genero) == [.assinatura, .historico])
    }

    // MARK: - Captura 1: as 3 tips e a URL crua

    @Test("as três dicas viram uma lista de verdade, com link de rótulo curto")
    func asTresDicasViramLista() {
        let corpo = CorpoLegivel.deTextoSimples(
            """
            Welcome to Resend.

            Here are 3 tips to get started:
            1. Send your first email https://resend.com/onboarding
            2. Verify your domain https://resend.com/domains
            3. Read the docs https://resend.com/docs
            """
        )
        let listas = corpo.blocos.compactMap { bloco -> Lista? in
            if case let .lista(lista) = bloco { return lista }
            return nil
        }
        #expect(listas.count == 1)
        #expect(listas.first?.ordenada == true)
        #expect(listas.first?.itens.count == 3)
        let primeiro = listas.first?.itens.first
        #expect(primeiro?.marcador == "1.")
        // O item é texto + link, e o link mostra o domínio, não sessenta
        // caracteres de URL.
        #expect(primeiro?.trechos.count == 2)
        #expect(primeiro?.trechos.first?.texto == "Send your first email ")
        #expect(primeiro?.trechos.last?.texto == "resend.com")
        #expect(primeiro?.trechos.last?.destino?.absoluteString == "https://resend.com/onboarding")
    }

    @Test("URL crua no meio da frase vira link com o domínio por rótulo")
    func urlCruaViraLink() {
        let corpo = CorpoLegivel.deTextoSimples(
            "Confira em https://www.resend.com/docs/introduction. Depois me diga."
        )
        guard case let .paragrafo(paragrafo) = corpo.blocos.first else {
            Issue.record("era para ser um parágrafo")
            return
        }
        #expect(paragrafo.trechos.count == 3)
        #expect(paragrafo.trechos[1].texto == "resend.com")
        #expect(
            paragrafo.trechos[1].destino?.absoluteString
                == "https://www.resend.com/docs/introduction"
        )
        // O ponto final da frase **não** entra no link.
        #expect(paragrafo.trechos[2].texto == ". Depois me diga.")
    }

    // MARK: - Captura 2: o formulário chave-valor

    @Test("o bloco chave-valor do formulário vira campos alinhados")
    func formularioViraCampos() {
        let corpo = CorpoLegivel.deTextoSimples(
            """
            Nova resposta no formulário do site.

            Nome: Maria Exemplo
            E-mail: maria@exemplo.com
            Mensagem: Gostaria de um orçamento para o projeto.
            Recebido em: 25/08/2026 09:41
            """
        )
        let campos = corpo.blocos.compactMap { bloco -> Campos? in
            if case let .campos(campos) = bloco { return campos }
            return nil
        }
        #expect(campos.count == 1)
        #expect(campos.first?.pares.map(\.chave) == ["Nome", "E-mail", "Mensagem", "Recebido em"])
        #expect(campos.first?.pares.first?.valorSimples == "Maria Exemplo")
    }

    @Test("uma linha solta com dois-pontos continua parágrafo, não vira campo")
    func umParSozinhoNaoEhTabela() {
        let corpo = CorpoLegivel.deTextoSimples("Assunto: isto aqui é uma frase inteira.")
        guard case .paragrafo = corpo.blocos.first else {
            Issue.record("um par sozinho não é uma tabela")
            return
        }
    }

    // MARK: - O email que já estava bom

    @Test("email sem citação, sem lista e sem campo passa intacto")
    func emailComumPassaIntacto() {
        let corpo = CorpoLegivel.deTextoSimples(
            """
            Oi, Marcos.

            Consegui adiantar a proposta e mando amanhã cedo.

            Abraço.
            """
        )
        #expect(corpo.dobras.isEmpty)
        #expect(corpo.blocos.count == 3)
        #expect(corpo.textoVisivel == "Oi, Marcos.\n\nConsegui adiantar a proposta e mando amanhã cedo.\n\nAbraço.")
    }

    @Test("corpo vazio não inventa bloco nenhum")
    func corpoVazio() {
        #expect(CorpoLegivel.deTextoSimples("   \n\n  ").blocos.isEmpty)
    }

    // MARK: - HTML

    @Test("a tabela HTML de duas colunas vira os mesmos campos alinhados")
    func tabelaHTMLViraCampos() {
        let corpo = CorpoLegivel.deHTML(
            """
            <style>td{padding:8px}</style>
            <p>Nova resposta no formulário do site.</p>
            <table>
              <tr><td>Nome</td><td>Maria Exemplo</td></tr>
              <tr><td>E-mail</td><td>maria@exemplo.com</td></tr>
              <tr><td>Recebido em</td><td>25/08/2026 09:41</td></tr>
            </table>
            """
        )
        let campos = corpo.blocos.compactMap { bloco -> Campos? in
            if case let .campos(campos) = bloco { return campos }
            return nil
        }
        #expect(campos.first?.pares.map(\.chave) == ["Nome", "E-mail", "Recebido em"])
        #expect(campos.first?.pares.last?.valorSimples == "25/08/2026 09:41")
    }

    @Test("lista, negrito e âncora do HTML sobrevivem")
    func listaNegritoEAncora() {
        let corpo = CorpoLegivel.deHTML(
            """
            <p>Olá, <strong>Marcos</strong>.</p>
            <ol>
              <li>Envie seu <a href="https://resend.com/onboarding">primeiro email</a></li>
              <li>Verifique o domínio</li>
            </ol>
            """
        )
        guard case let .paragrafo(paragrafo) = corpo.blocos.first else {
            Issue.record("o primeiro bloco é o parágrafo")
            return
        }
        #expect(paragrafo.trechos.contains { $0.texto == "Marcos" && $0.forte })

        guard case let .lista(lista) = corpo.blocos[1] else {
            Issue.record("o segundo bloco é a lista")
            return
        }
        #expect(lista.ordenada)
        #expect(lista.itens.count == 2)
        // A âncora manda no rótulo: o texto do link é o que a pessoa lê.
        let link = lista.itens[0].trechos.last
        #expect(link?.texto == "primeiro email")
        #expect(link?.destino?.absoluteString == "https://resend.com/onboarding")
    }

    @Test("blockquote do HTML é histórico, e dobra")
    func blockquoteDobra() {
        let corpo = CorpoLegivel.deHTML(
            "<div>Love the site!</div><blockquote><p>E aí, confirma?</p><p>Marina</p></blockquote>"
        )
        #expect(corpo.textoVisivel == "Love the site!")
        #expect(corpo.dobras.map(\.genero) == [.historico])
    }

    @Test("script e style não viram texto")
    func scriptNaoViraTexto() {
        let corpo = CorpoLegivel.deHTML(
            "<script>var a = 1;</script><style>p{color:red}</style><p>Só isto.</p>"
        )
        #expect(corpo.textoVisivel == "Só isto.")
    }

    // MARK: - A porta única

    @Test("a porta única prefere o HTML quando ele existe, e o texto quando não")
    func aPortaUnica() {
        let comHTML = CorpoLegivel.de(texto: "Olá", html: "<p>Olá, <b>mundo</b>.</p>")
        #expect(comHTML.textoVisivel == "Olá, mundo.")
        let semHTML = CorpoLegivel.de(texto: "Olá", html: nil)
        #expect(semHTML.textoVisivel == "Olá")
        let htmlVazio = CorpoLegivel.de(texto: "Olá", html: "   ")
        #expect(htmlVazio.textoVisivel == "Olá")
    }

    @Test("todo bloco e todo trecho tem identidade própria e estável")
    func identidadesUnicas() {
        let corpo = CorpoLegivel.deTextoSimples(
            """
            Um parágrafo com https://exemplo.com no meio.

            - item um
            - item dois

            Nome: Maria
            E-mail: maria@exemplo.com
            """
        )
        let ids = corpo.blocos.map(\.id)
        #expect(Set(ids).count == ids.count)
    }
}
