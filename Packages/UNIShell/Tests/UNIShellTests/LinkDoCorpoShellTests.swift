import AppKit
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// O clique num link do corpo: **ele não abre nada sozinho**, e o botão
/// direito desenha o painel do app.
///
/// As duas queixas do dono, uma suíte: "ainda aparece o tema do sistema" e "ao
/// clicar no link ele abre direto".
@Suite("O link do corpo, no app")
@MainActor
struct LinkDoCorpoShellTests {

    /// Um abridor que anota em vez de abrir. Nenhum teste deste projeto abre
    /// navegador — é a mesma injeção do `abreLink` da janela 04.
    final class Abridor {
        var abertos: [URL] = []
    }

    private func confirmacao() -> (LinkConfirmation, Abridor) {
        let abridor = Abridor()
        let confirm = LinkConfirmation { url in abridor.abertos.append(url) }
        return (confirm, abridor)
    }

    // MARK: - Clicar não abre

    @Test("clicar num link não abre nada: só levanta a pergunta")
    func cliqueNaoAbre() throws {
        let (confirm, abridor) = confirmacao()
        let url = try #require(URL(string: "https://banco.com@malicioso.example/onboarding"))
        #expect(confirm.pede(url))
        #expect(abridor.abertos.isEmpty, "o clique não pode ter aberto o navegador")
        #expect(confirm.pendente?.url == url)
        #expect(confirm.pendente?.destino.anfitriao == "malicioso.example")
    }

    @Test("só o botão de abrir abre, e uma vez só")
    func soOBotaoAbre() throws {
        let (confirm, abridor) = confirmacao()
        let url = try #require(URL(string: "https://resend.com/onboarding"))
        #expect(confirm.pede(url))
        confirm.abre()
        #expect(abridor.abertos == [url])
        #expect(confirm.pendente == nil, "a pergunta sai da tela depois de respondida")
        // Sem pedido no ar, "abrir" não tem o que abrir.
        confirm.abre()
        #expect(abridor.abertos == [url])
    }

    @Test("cancelar fecha sem abrir — e é o que o Esc faz")
    func cancelarNaoAbre() throws {
        let (confirm, abridor) = confirmacao()
        let url = try #require(URL(string: "https://resend.com/onboarding"))
        #expect(confirm.pede(url))
        confirm.cancela()
        #expect(confirm.pendente == nil)
        #expect(abridor.abertos.isEmpty)
    }

    /// Sem lista de confiança, sem "não perguntar de novo": o segundo clique no
    /// mesmo link pergunta de novo.
    @Test("o mesmo link pergunta toda vez")
    func perguntaSempre() throws {
        let (confirm, abridor) = confirmacao()
        let url = try #require(URL(string: "https://resend.com/onboarding"))
        #expect(confirm.pede(url))
        confirm.abre()
        #expect(confirm.pede(url), "não existe caminho que pule a pergunta")
        #expect(abridor.abertos.count == 1)
    }

    /// A regra dura: o que `ReaderHTMLPolicy.decide` recusa não abre **nem**
    /// pergunta.
    @Test("o que o leitor recusa não gera confirmação")
    func recusadoNaoPergunta() throws {
        let (confirm, abridor) = confirmacao()
        for cru in ["file:///etc/passwd", "javascript:alert(1)", "about:blank",
                    "data:text/html,<b>x"] {
            let url = try #require(URL(string: cru))
            #expect(!confirm.pede(url))
            #expect(confirm.pendente == nil)
        }
        #expect(abridor.abertos.isEmpty)
    }

    /// Uma fonte só para "o que pode sair para o mundo". Se as duas
    /// divergissem, o menu ofereceria o que o leitor recusa — ou o contrário.
    @Test("a política do leitor e o menu do link concordam, esquema a esquema")
    func politicaUnica() throws {
        for cru in ["https://a.example/x", "http://a.example/x", "mailto:a@b.example",
                    "tel:+551199", "file:///etc/passwd", "javascript:alert(1)",
                    "about:blank", "data:text/plain,x", "ftp://a.example/x",
                    "okamiuni://interno"] {
            let url = try #require(URL(string: cru))
            let abrivelPeloLeitor: Bool
            if case .abrirNoNavegador = ReaderHTMLPolicy.decide(url: url) {
                abrivelPeloLeitor = true
            } else {
                abrivelPeloLeitor = false
            }
            #expect(abrivelPeloLeitor == LinkDoCorpo.abrivel(url), "divergiram em \(cru)")
        }
    }

    // MARK: - O menu é o do app

    /// Nenhuma superfície do corpo entrega `NSMenu` ao sistema. É por aqui que
    /// o menu do `NSTextView` — "Buscar com Google", "Serviços", "Fala" —
    /// deixou de aparecer, sem tirar a seleção de texto de ninguém.
    @Test("a captura do botão direito não entrega NSMenu nenhum")
    func semNSMenu() throws {
        let catcher = RightClickCatcher.CatcherView()
        let evento = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        #expect(catcher.menu(for: evento) == nil)
        #expect(catcher.menu == nil)
    }

    /// A `View` não decide conteúdo: ela pergunta a `UNICore` e desenha.
    @Test("o menu de uma linha do corpo vem do modelo, com a legenda do destino")
    func menuDaLinha() throws {
        let url = try #require(URL(string: "https://resend.com.phish.example/onboarding"))
        let trechos = [
            Trecho(id: 0, texto: "Confirme em "),
            Trecho(id: 1, texto: "resend.com", destino: url),
        ]
        let entradas = LinkDoCorpo.menu(trechos: trechos)
        #expect(entradas.titles.first == "Vai para resend.com.phish.example")
        #expect(ContextMenuPanel.needsScroll(entradas) == false)
    }
}
