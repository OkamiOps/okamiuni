import Foundation
import Testing
@testable import UNICore

/// O link do corpo do email: para onde ele **realmente** vai, e o que o app
/// oferece sobre ele.
///
/// Tudo aqui é aritmética sobre a URL — nada de janela, nada de `View`. É o
/// que permite provar o caso que motivou a tarefa (`https://banco.com@…`) sem
/// abrir nada.
@Suite("O link do corpo")
struct LinkDoCorpoTests {

    // MARK: - O que pode abrir

    @Test("só os quatro esquemas do leitor abrem")
    func esquemas() {
        #expect(LinkDoCorpo.abrivel(URL(string: "https://resend.com/x")))
        #expect(LinkDoCorpo.abrivel(URL(string: "http://resend.com/x")))
        #expect(LinkDoCorpo.abrivel(URL(string: "mailto:zeno@resend.com")))
        #expect(LinkDoCorpo.abrivel(URL(string: "tel:+5511999999999")))
        #expect(!LinkDoCorpo.abrivel(URL(string: "file:///etc/passwd")))
        #expect(!LinkDoCorpo.abrivel(URL(string: "javascript:alert(1)")))
        #expect(!LinkDoCorpo.abrivel(URL(string: "about:blank")))
        #expect(!LinkDoCorpo.abrivel(URL(string: "data:text/html,<b>x")))
        #expect(!LinkDoCorpo.abrivel(nil))
    }

    // MARK: - O anfitrião

    @Test("o subdomínio inteiro é o anfitrião")
    func subdominio() throws {
        let url = try #require(URL(string: "https://mail.notificacoes.resend.com/onboarding?u=9"))
        let destino = try #require(LinkDoCorpo.destino(de: url))
        #expect(destino.anfitriao == "mail.notificacoes.resend.com")
        #expect(destino.prefixo == "https://")
        #expect(destino.resto == "/onboarding?u=9")
    }

    @Test("a porta fica fora do anfitrião, e continua visível")
    func porta() throws {
        let url = try #require(URL(string: "https://interno.example:8443/relatorio"))
        let destino = try #require(LinkDoCorpo.destino(de: url))
        #expect(destino.anfitriao == "interno.example")
        #expect(destino.resto == ":8443/relatorio")
        #expect(destino.porExtenso == "https://interno.example:8443/relatorio")
    }

    /// **O caso que a tarefa nomeia.** O que vem antes do `@` é usuário, não
    /// site: quem lê "banco.com" e clica cai em `malicioso.example`.
    @Test("usuário embutido não vira anfitrião")
    func usuarioEmbutido() throws {
        let url = try #require(URL(string: "https://banco.com@malicioso.example/onboarding"))
        let destino = try #require(LinkDoCorpo.destino(de: url))
        #expect(destino.anfitriao == "malicioso.example")
        #expect(destino.prefixo == "https://banco.com@")
        #expect(destino.resto == "/onboarding")
        #expect(destino.disfarcado, "usuário embutido é disfarce, e o cartão tem de dizer")
    }

    @Test("o anfitrião de um mailto é o domínio do endereço")
    func mailto() throws {
        let url = try #require(URL(string: "mailto:zeno@resend.com"))
        let destino = try #require(LinkDoCorpo.destino(de: url))
        #expect(destino.anfitriao == "resend.com")
        #expect(destino.prefixo == "mailto:zeno@")
        #expect(destino.porExtenso == "mailto:zeno@resend.com")
    }

    @Test("tel não tem anfitrião, e mesmo assim se lê por extenso")
    func telefone() throws {
        let url = try #require(URL(string: "tel:+5511999999999"))
        let destino = try #require(LinkDoCorpo.destino(de: url))
        #expect(destino.anfitriao == "")
        #expect(destino.porExtenso == "tel:+5511999999999")
    }

    /// IDN **não é decodificado**: decodificar é justamente o que engana.
    /// `xn--80ak6aa92e.com` desenhado como "аррӏе.com" é indistinguível de
    /// "apple.com" — então o app mostra a forma ASCII e diz que ela é IDN.
    @Test("punycode aparece como punycode, com aviso")
    func punycode() throws {
        let url = try #require(URL(string: "https://xn--80ak6aa92e.com/conta"))
        let destino = try #require(LinkDoCorpo.destino(de: url))
        #expect(destino.anfitriao == "xn--80ak6aa92e.com")
        #expect(destino.punycode)
        #expect(destino.disfarcado)
        #expect(!destino.anfitriao.contains("а"), "nada de alfabeto trocado na tela")

        let outro = try #require(URL(string: "https://resend.com/x"))
        let limpo = try #require(LinkDoCorpo.destino(de: outro))
        #expect(!limpo.punycode)
        #expect(!limpo.disfarcado)
    }

    /// O `Foundation` **decodifica** IDN sozinho: `URL(string:)` devolve o
    /// anfitrião já em cirílico. Se o app desenhasse o que ele devolve, o email
    /// escreveria "аррӏе.com" e a pessoa leria "apple.com". Estes vetores
    /// travam o caminho de volta.
    @Test("o anfitrião volta para ASCII, rótulo a rótulo")
    func punycodeVetores() {
        #expect(LinkDoCorpo.ascii(anfitriao: "аррӏе.com") == "xn--80ak6aa92e.com")
        #expect(LinkDoCorpo.ascii(anfitriao: "münchen.example") == "xn--mnchen-3ya.example")
        #expect(LinkDoCorpo.ascii(anfitriao: "Resend.COM") == "resend.com")
        #expect(LinkDoCorpo.ascii(anfitriao: "loja.münchen.example")
            == "loja.xn--mnchen-3ya.example")
    }

    @Test("anfitrião longo perde o meio, nunca o fim")
    func anfitriaoCurto() {
        let longo = "conta.seguranca.banco.com.br.verificacao.malicioso.example"
        let curto = LinkDoCorpo.anfitriaoCurto(longo, limite: 32)
        #expect(curto.count <= 32)
        #expect(curto.hasSuffix("malicioso.example"), "o fim é quem manda no destino")
        #expect(curto.contains("…"))
        #expect(LinkDoCorpo.anfitriaoCurto("resend.com", limite: 32) == "resend.com")
    }

    // MARK: - O menu

    @Test("um link: legenda com o anfitrião, abrir, copiar")
    func menuDeUmLink() throws {
        let url = try #require(URL(string: "https://banco.com@malicioso.example/onboarding"))
        let entradas = LinkDoCorpo.menu(links: [url], textoDoBloco: "Confirme sua conta")
        #expect(entradas.titles.first == "Vai para malicioso.example")
        #expect(entradas.commands.contains(.abrirLink(url: url)))
        #expect(entradas.commands.contains(.copy(url.absoluteString)))
        #expect(entradas.commands.contains(.copy("Confirme sua conta")))
        #expect(entradas.titles.contains { $0.contains("Abrir no navegador") })
        // Nada do menu do sistema entra aqui.
        for proibido in ["Buscar com Google", "Serviços", "Fala", "Ferramentas de Escrita",
                         "Ortografia", "Compartilhar", "Abrir com"] {
            #expect(!entradas.titles.contains { $0.contains(proibido) })
        }
    }

    @Test("o menu diz quando o domínio está disfarçado")
    func menuAvisaDisfarce() throws {
        let url = try #require(URL(string: "https://xn--80ak6aa92e.com/conta"))
        let entradas = LinkDoCorpo.menu(links: [url], textoDoBloco: "")
        #expect(entradas.titles.contains { $0.contains("IDN") })
    }

    @Test("mailto e tel não dizem “navegador”")
    func menuPorEsquema() throws {
        let correio = try #require(URL(string: "mailto:zeno@resend.com"))
        #expect(LinkDoCorpo.menu(links: [correio], textoDoBloco: "").titles
            .contains { $0.contains("Escrever para") })
        let fone = try #require(URL(string: "tel:+5511999999999"))
        #expect(LinkDoCorpo.menu(links: [fone], textoDoBloco: "").titles
            .contains { $0.contains("Ligar") })
    }

    @Test("vários links viram um submenu por anfitrião")
    func menuDeVariosLinks() throws {
        let a = try #require(URL(string: "https://resend.com/onboarding"))
        let b = try #require(URL(string: "https://resend.com.phish.example/onboarding"))
        let entradas = LinkDoCorpo.menu(links: [a, b], textoDoBloco: "Duas portas")
        #expect(entradas.titles.first == "2 links neste trecho")
        #expect(entradas.titles.contains("resend.com"))
        #expect(entradas.titles.contains("resend.com.phish.example"))
        #expect(entradas.submenuCommands("resend.com.phish.example")
            == [.abrirLink(url: b), .copy(b.absoluteString)])
    }

    /// Duas linhas com o mesmo rótulo é um menu em que se clica na sorte — e
    /// era o que saía com `https://resend.com/docs` ao lado de
    /// `mailto:zeno@resend.com`.
    @Test("links do mesmo anfitrião não viram duas linhas iguais")
    func menuDesempata() throws {
        let site = try #require(URL(string: "https://resend.com/docs"))
        let correio = try #require(URL(string: "mailto:zeno@resend.com"))
        let outraPagina = try #require(URL(string: "https://resend.com/onboarding"))
        let titulos = LinkDoCorpo.menu(
            links: [site, correio, outraPagina], textoDoBloco: ""
        ).titles
        #expect(Set(titulos).count == titulos.count, "nenhum rótulo se repete: \(titulos)")
        #expect(titulos.contains("mailto:zeno@resend.com"))
        #expect(titulos.contains("https://resend.com/docs"))
    }

    @Test("link repetido não repete linha")
    func menuSemRepeticao() throws {
        let url = try #require(URL(string: "https://resend.com/docs"))
        let entradas = LinkDoCorpo.menu(links: [url, url], textoDoBloco: "")
        #expect(entradas.commands.filter { $0 == .abrirLink(url: url) }.count == 1)
    }

    /// A regra dura da tarefa: o que a política do leitor recusa não gera menu
    /// **nem** confirmação.
    @Test("o que o leitor recusa não vira menu nenhum")
    func recusadoNaoTemMenu() throws {
        for cru in ["file:///etc/passwd", "javascript:alert(1)", "about:blank",
                    "data:text/html,<b>x", "ftp://exemplo.com/a"] {
            let url = try #require(URL(string: cru))
            #expect(LinkDoCorpo.menu(links: [url], textoDoBloco: "texto").isEmpty)
            #expect(LinkDoCorpo.destino(de: url) == nil)
        }
    }

    @Test("sem link não há menu, mesmo com texto")
    func semLinkSemMenu() {
        #expect(LinkDoCorpo.menu(links: [], textoDoBloco: "Um parágrafo qualquer").isEmpty)
    }

    @Test("menu bem formado: não abre nem fecha com traço")
    func menuArrumado() throws {
        let url = try #require(URL(string: "https://resend.com/docs"))
        let entradas = LinkDoCorpo.menu(links: [url], textoDoBloco: "")
        #expect(entradas.first?.isSeparator == false)
        #expect(entradas.last?.isSeparator == false)
    }

    // MARK: - A partir do que está desenhado

    @Test("os trechos de uma linha viram o menu daquela linha")
    func menuDeTrechos() throws {
        let url = try #require(URL(string: "https://resend.com/onboarding"))
        let trechos = [
            Trecho(id: 0, texto: "1. Envie o primeiro email "),
            Trecho(id: 1, texto: "resend.com", destino: url),
        ]
        let entradas = LinkDoCorpo.menu(trechos: trechos)
        #expect(entradas.titles.first == "Vai para resend.com")
        #expect(entradas.commands.contains(.abrirLink(url: url)))
        #expect(entradas.commands.contains(.copy("1. Envie o primeiro email resend.com")))
    }

    @Test("linha sem link não abre menu nenhum")
    func trechosSemLink() {
        #expect(LinkDoCorpo.menu(trechos: [Trecho(texto: "Só prosa.")]).isEmpty)
    }

    // MARK: - A legenda não é item

    @Test("a legenda do anfitrião não recebe realce nem clique")
    func legendaNaoEhItem() throws {
        let url = try #require(URL(string: "https://resend.com/docs"))
        let entradas = LinkDoCorpo.menu(links: [url], textoDoBloco: "")
        let legenda = try #require(entradas.first)
        #expect(!MenuKeyNavigation.isSelectable(legenda))
        // A primeira tecla ↓ pousa na primeira **ação**, e não na legenda.
        #expect(MenuKeyNavigation.first(in: entradas) == 1)
    }
}
