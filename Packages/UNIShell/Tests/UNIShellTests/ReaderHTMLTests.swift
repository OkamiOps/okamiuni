import AppKit
import Foundation
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// As decisões do leitor de HTML — todas puras, todas afirmáveis sem abrir
/// janela nenhuma. A `WebView` obedece a elas; o que se testa é elas.
@Suite("O leitor de HTML: o que ele deixa e o que ele barra")
struct ReaderHTMLPolicyTests {

    // MARK: A rede

    @Test("A lista de regras barra tudo o que for http ou https")
    func regraBarraORemoto() throws {
        let dados = try #require(ReaderHTMLPolicy.regraDeBloqueio.data(using: .utf8))
        let regras = try #require(
            try JSONSerialization.jsonObject(with: dados) as? [[String: Any]]
        )
        #expect(regras.count == 1)
        let gatilho = try #require(regras[0]["trigger"] as? [String: Any])
        #expect(gatilho["url-filter"] as? String == "^https?://")
        let acao = try #require(regras[0]["action"] as? [String: Any])
        // `block`, e não `block-cookies` nem `make-https`: o pixel de rastreio
        // não pode sair, e não basta sair sem cookie.
        #expect(acao["type"] as? String == "block")
    }

    @Test("A faixa aparece quando a mensagem pede imagem de fora")
    func detectaRecursoRemoto() {
        #expect(ReaderHTMLPolicy.pedeRecursoRemoto("<img src=\"https://x.example/p.gif\">"))
        #expect(ReaderHTMLPolicy.pedeRecursoRemoto("<td background=\"http://x/y.png\">"))
        #expect(ReaderHTMLPolicy.pedeRecursoRemoto("<div style=\"background:url(https://x/y)\">"))
    }

    @Test("Um link não é um recurso: a faixa não aparece por causa dele")
    func linkNaoContaComoRecurso() {
        // `href` não é carregado ao abrir, é seguido ao clicar. Contá-lo poria
        // a faixa em cima de toda mensagem com um link dentro — ou seja, em
        // quase todas.
        #expect(!ReaderHTMLPolicy.pedeRecursoRemoto("<a href=\"https://ok.example\">Site</a>"))
        #expect(!ReaderHTMLPolicy.pedeRecursoRemoto("<p>Sem nada de fora.</p>"))
        // A imagem já embutida na mensagem não é rede.
        #expect(!ReaderHTMLPolicy.pedeRecursoRemoto("<img src=\"data:image/png;base64,AAA\">"))
    }

    // MARK: Os cliques

    @Test("Link http sai para o navegador; a WebView nunca navega")
    func linkVaiParaONavegador() {
        let alvo = URL(string: "https://exemplo.com/promo")!
        #expect(ReaderHTMLPolicy.decide(url: alvo) == .abrirNoNavegador(alvo))
        let correio = URL(string: "mailto:alguem@x.com")!
        #expect(ReaderHTMLPolicy.decide(url: correio) == .abrirNoNavegador(correio))
    }

    @Test("A carga do próprio documento passa; o resto é recusado")
    func documentoPassaORestoNao() {
        #expect(ReaderHTMLPolicy.decide(url: URL(string: "about:blank")!) == .permitir)
        // `file:` dentro de um leitor de email é a leitura do disco da pessoa
        // por uma mensagem de estranho.
        #expect(ReaderHTMLPolicy.decide(url: URL(string: "file:///etc/passwd")!) == .recusar)
        #expect(ReaderHTMLPolicy.decide(url: nil) == .recusar)
    }

    // MARK: As cores

    @Test("A mensagem que escolheu as cores dela é desenhada em papel branco")
    func mensagemComCorViraPapel() {
        #expect(ReaderHTMLPolicy.paleta(para: "<td bgcolor=\"#ffffff\">Oi</td>") == .papel)
        #expect(ReaderHTMLPolicy.paleta(para: "<p style=\"color:#333\">Oi</p>") == .papel)
        // A mensagem que não disse nada segue o tema — e fica bonita nos dois.
        #expect(ReaderHTMLPolicy.paleta(para: "<p>Bom dia.</p>") == .doTema)
    }

    @Test("O documento leva color-scheme, fundo e tinta — nunca texto invisível")
    func documentoTemasEscolhidos() {
        let doTema = ReaderHTMLPolicy.documento(
            html: "<p>Bom dia.</p>", fundo: "rgba(20, 20, 20, 1.0)",
            tinta: "rgba(240, 240, 240, 1.0)", link: "rgba(120, 170, 255, 1.0)",
            fonte: "ui-serif"
        )
        #expect(doTema.contains("color-scheme: light dark"))
        #expect(doTema.contains("rgba(20, 20, 20, 1.0)"))
        #expect(doTema.contains("rgba(240, 240, 240, 1.0)"))
        #expect(doTema.contains("<p>Bom dia.</p>"))

        // O email do provedor num tema escuro: papel branco, tinta escura, e o
        // fundo do tema **não** entra. Sem isto, um bloco com texto escuro
        // declarado pelo remetente cairia sobre o fundo escuro do app.
        let papel = ReaderHTMLPolicy.documento(
            html: "<td bgcolor=\"#fff\">Oi</td>", fundo: "rgba(20, 20, 20, 1.0)",
            tinta: "rgba(240, 240, 240, 1.0)", link: "rgba(120, 170, 255, 1.0)",
            fonte: "ui-serif"
        )
        #expect(papel.contains("#ffffff"))
        #expect(!papel.contains("rgba(20, 20, 20, 1.0)"))
        #expect(papel.contains("color-scheme: light"))
        #expect(!papel.contains("color-scheme: light dark"))
    }

    @Test("A imagem larga não empurra o painel para o lado")
    func imagemCabe() {
        let documento = ReaderHTMLPolicy.documento(
            html: "<img src=\"cid:x\">", fundo: "#fff", tinta: "#000",
            link: "#00f", fonte: "ui-serif"
        )
        #expect(documento.contains("max-width: 100%"))
        // A `WebView` não rola: quem rola é o leitor.
        #expect(documento.contains("overflow: hidden"))
    }

    // MARK: A faixa e as cores do tema

    @Test("A frase da faixa é a do design")
    func aFraseDaFaixa() {
        #expect(ReaderHTMLSection.imagensBloqueadas == "Imagens remotas bloqueadas")
        #expect(ReaderHTMLSection.carregar == "Carregar")
    }

    @Test("O token vira rgba, com a opacidade que ele tem")
    func tokenViraCSS() {
        #expect(
            ReaderHTMLSection.css(TokenColor(red: 1, green: 0, blue: 0.5, opacity: 0.5))
                == "rgba(255, 0, 128, 0.5)"
        )
    }
}

/// O cartão do convite, e o corpo que passa a ser HTML.
@Suite("O leitor com convite e com HTML")
struct ReaderInviteTests {
    private static let conta = Account(
        id: "a", address: "eu@x.com", displayName: "Eu",
        provider: .imap, host: "host", tintLightHex: "#3E6FA8", tintDarkHex: "#7BA8D9"
    )

    private static let convite = """
        BEGIN:VCALENDAR
        METHOD:REQUEST
        BEGIN:VEVENT
        SUMMARY:Revisão do contrato
        DTSTART;TZID=America/Sao_Paulo:20260827T150000
        DTEND;TZID=America/Sao_Paulo:20260827T160000
        LOCATION:Sala 4
        ORGANIZER;CN=Marina Duarte:mailto:marina@x.com
        ATTENDEE;CN=Eu:mailto:eu@x.com
        END:VEVENT
        END:VCALENDAR
        """

    private static func mensagem(
        corpo: [String] = [], html: String? = "", ics: String? = nil
    ) -> Message {
        Message(
            id: "m", accountID: "a",
            from: Contact(name: "Marina", address: "marina@x.com"),
            receivedAt: Date(timeIntervalSince1970: 1_800_000_000),
            subject: "Convite", snippet: "Convite", body: corpo, tags: [],
            bucket: .today, isRead: false, summary: nil, detectedEvent: nil,
            bodyHTML: html, calendarICS: ics
        )
    }

    @MainActor
    private static func store(_ mensagem: Message) async -> MailStore {
        let store = MailStore(
            source: InMemoryMailSource(accounts: [conta], messages: [mensagem], agenda: [])
        )
        await store.load()
        store.select(message: "m")
        return store
    }

    @MainActor
    private static func desenha(_ store: MailStore) -> NSBitmapImageRep? {
        Render.bitmap(
            ReaderPane(store: store), size: CGSize(width: 760, height: 700), theme: .tinta
        )
    }

    @Test("A mensagem com `text/calendar` tem convite; a sem, não")
    func leOConvite() throws {
        let comConvite = try #require(ReaderPane.convite(de: Self.mensagem(ics: Self.convite)))
        #expect(comConvite.summary == "Revisão do contrato")
        #expect(ReaderPane.convite(de: Self.mensagem()) == nil)
        // Um `text/calendar` que não é calendário nenhum também não vira cartão.
        #expect(ReaderPane.convite(de: Self.mensagem(ics: "lixo")) == nil)
    }

    @Test("O organizador vem primeiro e não aparece duas vezes")
    func quemEstaNoConvite() throws {
        let lido = try #require(ICalendar.parse("""
            BEGIN:VCALENDAR
            BEGIN:VEVENT
            ORGANIZER;CN=Marina:mailto:marina@x.com
            ATTENDEE;CN=Marina:mailto:marina@x.com
            ATTENDEE;CN=Eu:mailto:eu@x.com
            END:VEVENT
            END:VCALENDAR
            """))
        #expect(ReaderPane.participantes(lido) == "Marina, Eu")
        #expect(ReaderPane.participantes(CalendarInvite(summary: "", start: nil, end: nil)) == nil)
    }

    @Test("As frases do cartão")
    func asFrasesDoCartao() {
        #expect(ReaderPane.conviteTitulo == "Convite de agenda")
        #expect(ReaderPane.conviteCancelado == "Convite cancelado")
    }

    /// **Prova por mutação do cartão.** As duas telas têm o mesmo cabeçalho, o
    /// mesmo assunto e o mesmo remetente: um `ReaderPane` que ignorasse o
    /// `calendarICS` — que é o estado de antes desta tarefa — desenharia as
    /// duas idênticas, pixel a pixel, com "Esta mensagem não tem texto" nas
    /// duas.
    @Test("O convite desenha um cartão onde antes havia 'esta mensagem não tem texto'")
    @MainActor
    func oCartaoAparece() async throws {
        let semConvite = try #require(Self.desenha(await Self.store(Self.mensagem())))
        let comConvite = try #require(
            Self.desenha(await Self.store(Self.mensagem(ics: Self.convite)))
        )
        #expect(
            comConvite.pixelsDiffering(from: semConvite) > 0,
            "o convite não desenhou nada — o cartão é a tarefa inteira"
        )
    }

    /// **Prova por mutação do modo HTML.** A mesma mensagem, o mesmo texto: o
    /// que muda é haver ou não uma parte HTML. Um leitor que desenhasse os
    /// parágrafos nos dois casos — que é o estado de antes — renderizaria as
    /// duas telas iguais.
    @Test("A mensagem com HTML é desenhada como HTML, não como parágrafos")
    @MainActor
    func oModoHTMLAparece() async throws {
        let soTexto = try #require(
            Self.desenha(await Self.store(Self.mensagem(corpo: ["Bom dia."])))
        )
        let comHTML = try #require(Self.desenha(await Self.store(Self.mensagem(
            corpo: ["Bom dia."],
            html: "<h1 style=\"color:#b00\">Bom dia.</h1><table><tr><td>Um</td></tr></table>"
        ))))
        #expect(
            comHTML.pixelsDiffering(from: soTexto) > 0,
            "o HTML desenhou igual ao texto seco — é a queixa que abriu a M3-8"
        )
    }

    @Test("Sem HTML, o leitor continua sendo o de sempre — as fixtures não mudam um pixel")
    @MainActor
    func semHTMLNadaMuda() async throws {
        // `bodyHTML: nil` (fixture do Marco 1) e `bodyHTML: ""` (decodificada e
        // sem HTML) desenham a mesma coisa: os parágrafos.
        let fixture = try #require(
            Self.desenha(await Self.store(Self.mensagem(corpo: ["Bom dia."], html: nil)))
        )
        let resolvida = try #require(
            Self.desenha(await Self.store(Self.mensagem(corpo: ["Bom dia."], html: "")))
        )
        #expect(resolvida.pixelsDiffering(from: fixture) == 0)
    }
}
