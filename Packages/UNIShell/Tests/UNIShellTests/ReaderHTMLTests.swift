import AppKit
import Foundation
import SwiftUI
import Testing
import UNICore
import UNIDesign
import WebKit
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

    @Test("Imagem protocol-relative é bloqueada sem deixar ícone quebrado")
    func imagemProtocolRelative() {
        let html = """
            <a href="//okamiops.com">Abrir</a>
            <img src="//cdn.exemplo.com/logo.png">
            <div style="background-image: url('//cdn.exemplo.com/fundo.png')"></div>
            """
        #expect(ReaderHTMLPolicy.pedeRecursoRemoto(html))

        let bloqueado = ReaderHTMLPolicy.documento(
            html: html, fundo: "#fff", tinta: "#000", link: "#00f", fonte: "ui-serif",
            bloqueiaRemotas: true
        )
        #expect(bloqueado.contains("href=\"//okamiops.com\""))
        #expect(!bloqueado.contains("src=\"//cdn.exemplo.com/logo.png\""))
        #expect(!bloqueado.contains("url('//cdn.exemplo.com/fundo.png')"))
        #expect(bloqueado.contains(ReaderHTMLPolicy.imagemRemotaBloqueada))
    }

    @Test("Imagem http vira https — senão o ATS quebra o ícone do Google Play")
    func promoveHTTPParaHTTPS() {
        let html = """
            <img src="http://www.gstatic.com/android/market_images/email/alert_outline.png">
            <a href="http://play.google.com/pay">Atualizar</a>
            <div style="background: url(&#39;http://www.gstatic.com/android/market_images/email/email_mid_v2.png&#39;)"></div>
            <html xmlns="http://www.w3.org/1999/xhtml">
            """
        let livre = ReaderHTMLPolicy.documento(
            html: html, fundo: "#fff", tinta: "#000", link: "#00f", fonte: "ui-serif",
            bloqueiaRemotas: false
        )
        #expect(livre.contains("src=\"https://www.gstatic.com/android/market_images/email/alert_outline.png\""))
        #expect(!livre.contains("src=\"http://www.gstatic.com"))
        // O destino do clique não muda: HTTP claro num link ainda é o que o
        // remetente escreveu.
        #expect(livre.contains("href=\"http://play.google.com/pay\""))
        #expect(livre.contains("url(&#39;https://www.gstatic.com/android/market_images/email/email_mid_v2.png&#39;)"))
        #expect(livre.contains("xmlns=\"http://www.w3.org/1999/xhtml\""))

        let bloqueado = ReaderHTMLPolicy.documento(
            html: html, fundo: "#fff", tinta: "#000", link: "#00f", fonte: "ui-serif",
            bloqueiaRemotas: true
        )
        #expect(bloqueado.contains(ReaderHTMLPolicy.imagemRemotaBloqueada))
        #expect(!bloqueado.contains("alert_outline.png"))
    }

    @Test("http no loopback continua: é o servidor de ensaio das imagens")
    func naoPromoveLoopback() {
        let html = "<img src=\"http://127.0.0.1:9/pixel.png\">"
        let livre = ReaderHTMLPolicy.documento(
            html: html, fundo: "#fff", tinta: "#000", link: "#00f", fonte: "ui-serif",
            bloqueiaRemotas: false
        )
        #expect(livre.contains("http://127.0.0.1:9/pixel.png"))
        #expect(!livre.contains("https://127.0.0.1"))
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

    @Test("Sim/Não/Talvez do Google Agenda viram RSVP, não uma aba")
    func rsvpDoGoogleNaoAbreONavegador() {
        let sim = URL(string: "https://calendar.google.com/calendar/event?action=RESPOND&eid=abc&rst=1")!
        let nao = URL(string: "https://www.google.com/calendar/event?action=RESPOND&rst=2&eid=abc")!
        let talvez = URL(string: "https://calendar.google.com/calendar/event?eid=abc&rst=3")!
        let soVer = URL(string: "https://calendar.google.com/calendar/event?eid=abc")!
        #expect(ReaderHTMLPolicy.decide(url: sim) == .rsvp(.accepted))
        #expect(ReaderHTMLPolicy.decide(url: nao) == .rsvp(.declined))
        #expect(ReaderHTMLPolicy.decide(url: talvez) == .rsvp(.tentative))
        #expect(ReaderHTMLPolicy.decide(url: soVer) == .abrirNoNavegador(soVer))
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
        #expect(ReaderHTMLPolicy.paleta(para: "<span color=\"#333\">Oi</span>") == .papel)
        #expect(
            ReaderHTMLPolicy.paleta(
                para: "<style>@media (prefers-color-scheme: dark) { p { color:#eee } }</style><p>Oi</p>"
            ) == .papel
        )
        // A mensagem que não disse nada segue o tema — e fica bonita nos dois.
        #expect(ReaderHTMLPolicy.paleta(para: "<p>Bom dia.</p>") == .doTema)
    }

    @Test("Como o tema força o HTML pintado a seguir o app")
    func paletaForcadaDoTema() {
        let html = "<td bgcolor=\"#ffffff\">Oi</td>"
        #expect(ReaderHTMLPolicy.paleta(para: html) == .papel)
        #expect(ReaderHTMLPolicy.paleta(para: html, forçada: .doTema) == .doTema)
        let forçado = ReaderHTMLPolicy.documento(
            html: html, fundo: "rgba(20, 20, 20, 1.0)",
            tinta: "rgba(240, 240, 240, 1.0)", link: "rgba(120, 170, 255, 1.0)",
            fonte: "ui-serif", paleta: .doTema
        )
        #expect(forçado.contains("rgba(20, 20, 20, 1.0)"))
        #expect(!forçado.contains("color-scheme: light only"))
        #expect(forçado.contains("id=\"uni-tema\""))
        #expect(forçado.contains("background-color: transparent !important"))
        #expect(forçado.contains("color: rgba(240, 240, 240, 1.0) !important"))
        #expect(ReaderHTMLSection.comoEnviado == "Como enviado")
        #expect(ReaderHTMLSection.comoOTema == "Como o tema")
    }

    @Test("Como o tema ganha do @media dark do Calendar e do bgcolor branco")
    func paletaForcadaCobreORemetente() {
        let convite = """
            <style>@media (prefers-color-scheme: dark) { .txt { color:#e8eaed !important } }</style>
            <table bgcolor="#ffffff"><tr><td class="txt">Quando</td></tr></table>
            """
        let forçado = ReaderHTMLPolicy.documento(
            html: convite, fundo: "rgba(11, 11, 18, 1.0)",
            tinta: "rgba(226, 227, 236, 1.0)", link: "rgba(120, 170, 255, 1.0)",
            fonte: "ui-serif", paleta: .doTema
        )
        let automatico = ReaderHTMLPolicy.documento(
            html: convite, fundo: "rgba(11, 11, 18, 1.0)",
            tinta: "rgba(226, 227, 236, 1.0)", link: "rgba(120, 170, 255, 1.0)",
            fonte: "ui-serif"
        )
        #expect(forçado.contains("id=\"uni-tema\""))
        #expect(!automatico.contains("id=\"uni-tema\""))
        #expect(automatico.contains("color-scheme: light only"))
        let indiceTema = forçado.range(of: "id=\"uni-tema\"")!.lowerBound
        let indiceQuando = forçado.range(of: "Quando")!.lowerBound
        #expect(indiceTema > indiceQuando)
    }

    @Test("papel trava o esquema em light only, para o Calendar não clarear o texto")
    func papelTravaEsquemaClaro() {
        let convite = """
            <style>@media (prefers-color-scheme: dark) { .txt { color:#e8eaed !important } }</style>
            <table bgcolor="#ffffff"><tr><td class="txt">Quando</td></tr></table>
            """
        let papel = ReaderHTMLPolicy.documento(
            html: convite, fundo: "rgba(11, 11, 18, 1.0)",
            tinta: "rgba(185, 186, 200, 1.0)", link: "rgba(120, 170, 255, 1.0)",
            fonte: "ui-serif"
        )
        #expect(papel.contains("color-scheme: light only"))
        #expect(papel.contains("name=\"color-scheme\" content=\"light\""))
        #expect(ReaderHTMLPolicy.esquemaClaro(
            html: convite, fundo: "rgba(11, 11, 18, 1.0)", tinta: "rgba(185, 186, 200, 1.0)"
        ))
        // O id do invólucro não pinta tinta do tema por cima das classes.
        #expect(!papel.contains("#uni-root { display: block; color:"))
    }

    @Test("O documento leva color-scheme, fundo e tinta — nunca texto invisível")
    func documentoTemasEscolhidos() {
        let doTema = ReaderHTMLPolicy.documento(
            html: "<p>Bom dia.</p>", fundo: "rgba(20, 20, 20, 1.0)",
            tinta: "rgba(240, 240, 240, 1.0)", link: "rgba(120, 170, 255, 1.0)",
            fonte: "ui-serif"
        )
        #expect(doTema.contains("color-scheme: dark"))
        #expect(!doTema.contains("color-scheme: light dark"))
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
        #expect(papel.contains("color-scheme: light only"))
        #expect(!papel.contains("color-scheme: light dark"))

        let claro = ReaderHTMLPolicy.documento(
            html: "<p>Bom dia.</p>", fundo: "#ffffff",
            tinta: "#222222", link: "#1155cc", fonte: "ui-serif"
        )
        #expect(claro.contains("color-scheme: light"))
        #expect(!claro.contains("color-scheme: dark"))
    }

    @Test("página escura é a que tem tinta mais clara que o fundo")
    func paginaEscuraPelaTinta() {
        #expect(ReaderHTMLPolicy.paginaEscura(fundo: "#0B0B12", tinta: "#B9BAC8"))
        #expect(ReaderHTMLPolicy.paginaEscura(fundo: "rgba(11, 11, 18, 1.0)", tinta: "rgba(185, 186, 200, 1.0)"))
        #expect(!ReaderHTMLPolicy.paginaEscura(fundo: "#ffffff", tinta: "#1a1a1a"))
    }

    @Test("O fechamento quebrado do pré-cabeçalho é recuperado antes de desenhar")
    func fechamentoQuebradoViraTagDeVerdade() {
        let consertado = ReaderHTMLPolicy.recuperaFechamentosQuebrados(
            "<div style=\"display:none\">x<=\"\" div=\"\"><table><tr><td>615211</td></tr></table>"
        )
        #expect(consertado.contains("</div>"))
        #expect(!consertado.contains("<=\"\""))
        #expect(
            ReaderHTMLPolicy.documento(
                html: consertado, fundo: "#fff", tinta: "#000",
                link: "#00f", fonte: "ui-serif"
            ).contains("</div>")
        )
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

    /// A queixa do GitHub Actions: "Status" pintado letra a letra. A folha
    /// antiga punha `word-break: break-word` no `body` (herdado por toda
    /// célula) e `max-width: 100%` em `table`. Numa tabela fluida, a coluna
    /// estreita passa a ter min-content de um caractere — e "Status" vira
    /// S / t / a / t / u / s.
    @Test("A folha não parte palavra no meio nem espreme tabela")
    func folhaNaoParteCelula() {
        let documento = ReaderHTMLPolicy.documento(
            html: "<table><tr><td>Status</td></tr></table>",
            fundo: "#fff", tinta: "#000", link: "#00f", fonte: "ui-serif"
        )
        #expect(!documento.contains("word-break"))
        #expect(documento.contains("overflow-wrap: break-word"))
        #expect(documento.contains("img, video { max-width: 100%"))
        #expect(!documento.contains("img, video, table { max-width: 100%"))
    }

    @Test("A folha força seleção de texto — emails de 2FA não podem recusar")
    func folhaForcaSelecao() {
        let documento = ReaderHTMLPolicy.documento(
            html: "<p style=\"user-select:none\">482911</p>",
            fundo: "#fff", tinta: "#000", link: "#00f", fonte: "ui-serif"
        )
        #expect(documento.contains("user-select: text !important"))
        #expect(documento.contains("-webkit-user-select: text !important"))
    }

    @Test("⌘C e ⌘A passam para o HTML; ⌘R continua do app")
    @MainActor
    func atalhosDeCopiaPassam() throws {
        #expect(WebViewQueNaoRouba(frame: .zero, configuration: .init()).acceptsFirstResponder)
        let copiar = try #require(Self.atalho("c", .command))
        let selecionar = try #require(Self.atalho("a", .command))
        let recarregar = try #require(Self.atalho("r", .command))
        let escrever = try #require(Self.atalho("n", .command))
        #expect(WebViewQueNaoRouba.atalhoDeCopia(copiar))
        #expect(WebViewQueNaoRouba.atalhoDeCopia(selecionar))
        #expect(!WebViewQueNaoRouba.atalhoDeCopia(recarregar))
        #expect(!WebViewQueNaoRouba.atalhoDeCopia(escrever))
    }

    @Test("O HTML do leitor não engole o ⌫ — apagar continua sendo da mensagem")
    @MainActor
    func leitorNaoECampoDeTexto() {
        let web = WebViewQueNaoRouba(frame: .zero, configuration: .init())
        #expect(!web.eCampoDeTexto)
        #expect(!BareKeyFocus.isEditingText(web))
        let campo = NSTextView(frame: .zero)
        #expect(BareKeyFocus.isEditingText(campo))
        web.eCampoDeTexto = true
        #expect(BareKeyFocus.isEditingText(web))
    }

    @Test("Esc na busca vale; no composer, o documento fica com a tecla")
    @MainActor
    func escDistingueBuscaDeDocumento() {
        let editor = NSTextView(frame: .zero)
        editor.isFieldEditor = true
        #expect(!BareKeyFocus.isEditingDocument(editor))
        let composer = NSTextView(frame: .zero)
        #expect(BareKeyFocus.isEditingDocument(composer))
        let field = NSTextField(frame: .zero)
        field.setAccessibilityIdentifier(BareKeyFocus.searchFieldID)
        #expect(BareKeyFocus.isSearchField(field))
        #expect(!BareKeyFocus.isSearchField(composer))
        #expect(!BareKeyFocus.isEditingDocument(nil))
    }

    private static func atalho(_ tecla: String, _ flags: NSEvent.ModifierFlags) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: tecla,
            charactersIgnoringModifiers: tecla,
            isARepeat: false,
            keyCode: 0
        )
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
        #expect(ReaderPane.participantesResumo(lido) == "Marina, Eu")
        let cheio = try #require(ICalendar.parse("""
            BEGIN:VCALENDAR
            BEGIN:VEVENT
            ORGANIZER;CN=A:mailto:a@x.com
            ATTENDEE;CN=B:mailto:b@x.com
            ATTENDEE;CN=C:mailto:c@x.com
            ATTENDEE;CN=D:mailto:d@x.com
            ATTENDEE;CN=E:mailto:e@x.com
            END:VEVENT
            END:VCALENDAR
            """))
        #expect(ReaderPane.participantesResumo(cheio) == "A, B, C e mais 2")
        #expect(ReaderPane.conviteComecaAberto(responded: false, cancelled: false))
        #expect(!ReaderPane.conviteComecaAberto(responded: true, cancelled: false))
        #expect(ReaderPane.conviteComecaAberto(responded: true, cancelled: true))
        #expect(ReaderPane.recolherConvite == "Recolher")
        #expect(ReaderPane.mostrarConvite == "Detalhes")
        #expect(!ReaderPane.resumoComecaAberto)
        #expect(ReaderPane.recolherResumo == "Recolher resumo")
        #expect(ReaderPane.mostrarResumo == "Mostrar resumo")
    }

    @Test("As frases do cartão")
    func asFrasesDoCartao() {
        #expect(ReaderPane.conviteTitulo == "Convite de agenda")
        #expect(ReaderPane.conviteCancelado == "Convite cancelado")
        #expect(ReaderPane.removerDaAgenda == "Remover da agenda")
        #expect(ReaderPane.conviteCanceladoFora == "Este compromisso não está na sua agenda.")
        #expect(ReaderPane.conviteCanceladoNaAgenda == "Na agenda como cancelado.")
        #expect(ReaderPane.conviteNaAgenda == "Na agenda")
        #expect(ReaderPane.identityCaption(name: "Marina", subject: "Contrato") == "Marina · Contrato")
    }

    /// O botão do cartão fala os três estados. Ele dizia sempre "Colocar na
    /// agenda", e clicar sempre criava — foi assim que o convite e o "Convite
    /// atualizado" do mesmo evento viraram dois blocos "DreamSquad".
    @Test("O botão do convite diz o que vai fazer nos três estados")
    func asFrasesDoBotao() {
        #expect(ReaderPane.inviteButtonLabel(.ausente) == "Colocar na agenda")
        #expect(ReaderPane.inviteButtonLabel(.naAgenda) == "Na agenda")
        #expect(ReaderPane.inviteButtonLabel(.desatualizado) == "Atualizar na agenda")
        #expect(ReaderPane.inviteButtonHelp(.desatualizado).contains("Atualiza"))
    }

    /// O cartão pergunta o estado **ao desenhar**: abrir de novo a mensagem de
    /// um convite que já está na agenda mostra "Na agenda" sem clique nenhum.
    @Test("O cartão do convite já aberto na agenda não oferece colocar de novo")
    @MainActor
    func oCartaoSabeQueJaEsta() async throws {
        let mensagem = Self.mensagem(ics: Self.convite)
        let store = await Self.store(mensagem)
        let lido = try #require(ReaderPane.convite(de: mensagem))
        #expect(store.agendaState(for: lido, from: mensagem) == .ausente)
        store.addToAgenda(lido, from: mensagem)
        #expect(store.agendaState(for: lido, from: mensagem) == .naAgenda)
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
