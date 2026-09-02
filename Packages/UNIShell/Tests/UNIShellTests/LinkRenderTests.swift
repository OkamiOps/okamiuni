import AppKit
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// O desenho das duas peças novas: o menu do link e o cartão da pergunta.
///
/// Nada aqui abre janela de menu de verdade — o painel é uma `View`, e é ela
/// que se fotografa. Abrir a janela do apresentador roubaria o foco da máquina
/// de quem roda a suíte, que é a regra deste harness.
@Suite("O desenho do link")
@MainActor
struct LinkRenderTests {

    private func url(_ cru: String) throws -> URL {
        try #require(URL(string: cru))
    }

    private func tinta(_ rep: NSBitmapImageRep, fundo: TokenColor) -> Int {
        rep.pixelsWide * rep.pixelsHigh - rep.pixels(matching: fundo, tolerance: 0.03)
    }

    private func painel(_ entradas: [ContextMenuEntry], tema: Theme) -> some View {
        // Realce na primeira **ação**, como o ponteiro o deixaria: é o estado
        // em que a pessoa vê o menu de verdade.
        ContextMenuPanel(
            level: MenuLevel(entries: entradas, highlighted: MenuKeyNavigation.first(in: entradas))
        )
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(tema.paper.color)
    }

    // MARK: - O menu

    @Test("o menu do link desenha em okami e em tinta")
    func menuDesenha() throws {
        let entradas = LinkDoCorpo.menu(
            links: [try url("https://banco.com@malicioso.example/onboarding")],
            textoDoBloco: "Confirme sua conta agora"
        )
        for tema in [Theme.okami, Theme.tinta] {
            let sufixo = tema.id == "tinta" ? "-tinta" : ""
            let rep = try #require(
                Render.snapshot(
                    painel(entradas, tema: tema),
                    named: "menu-link\(sufixo)",
                    size: CGSize(width: 380, height: 220),
                    theme: tema,
                    scale: 2
                )
            )
            #expect(tinta(rep, fundo: tema.paper) > 500, "o menu saiu em branco em \(tema.id)")
        }
    }

    @Test("o menu de vários links desenha um submenu por anfitrião")
    func menuVariosDesenha() throws {
        let entradas = LinkDoCorpo.menu(
            links: [
                try url("https://resend.com/onboarding"),
                try url("https://resend.com.phish.example/entrar"),
                try url("mailto:zeno@resend.com"),
            ],
            textoDoBloco: "Três portas"
        )
        for tema in [Theme.okami, Theme.tinta] {
            let sufixo = tema.id == "tinta" ? "-tinta" : ""
            let rep = try #require(
                Render.snapshot(
                    painel(entradas, tema: tema),
                    named: "menu-link-varios\(sufixo)",
                    size: CGSize(width: 380, height: 220),
                    theme: tema,
                    scale: 2
                )
            )
            #expect(tinta(rep, fundo: tema.paper) > 500)
        }
    }

    /// A legenda é o que transforma o menu em defesa. Se ela sumisse do
    /// desenho, este teste continuaria passando por acaso — a menos que ele
    /// compare com o mesmo menu **sem** ela, que é o que faz aqui.
    @Test("a legenda do anfitrião está desenhada, e não só na lista")
    func legendaAparece() throws {
        let entradas = LinkDoCorpo.menu(
            links: [try url("https://malicioso.example/onboarding")], textoDoBloco: ""
        )
        let semLegenda = entradas.filter {
            switch $0 {
            case .legenda, .aviso: false
            default: true
            }
        }
        #expect(entradas.count == semLegenda.count + 1)
        let tema = Theme.tinta
        let tamanho = CGSize(width: 380, height: 220)
        let com = try #require(Render.bitmap(painel(entradas, tema: tema), size: tamanho, theme: tema))
        let sem = try #require(
            Render.bitmap(painel(semLegenda, tema: tema), size: tamanho, theme: tema)
        )
        #expect(com.pixelsDiffering(from: sem) > 0, "a legenda não chegou à tela")
        #expect(tinta(com, fundo: tema.paper) > tinta(sem, fundo: tema.paper))
    }

    // MARK: - O cartão da pergunta

    private func cartao(_ destino: LinkDoCorpo.Destino, tema: Theme) -> some View {
        LinkConfirmCard(
            destino: destino,
            rotuloDeAbertura: "Abrir no navegador",
            onOpen: {}, onCancel: {}
        )
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(tema.paper.color)
    }

    @Test("o cartão da pergunta desenha em okami e em tinta")
    func cartaoDesenha() throws {
        let destino = try #require(
            LinkDoCorpo.destino(de: try url("https://banco.com@malicioso.example/onboarding"))
        )
        for tema in [Theme.okami, Theme.tinta] {
            let sufixo = tema.id == "tinta" ? "-tinta" : ""
            let rep = try #require(
                Render.snapshot(
                    cartao(destino, tema: tema),
                    named: "confirmacao-link\(sufixo)",
                    size: CGSize(width: 420, height: 330),
                    theme: tema,
                    scale: 2
                )
            )
            #expect(tinta(rep, fundo: tema.paper) > 1000)
        }
    }

    @Test("o cartão de um link limpo e o de um disfarçado não são o mesmo desenho")
    func cartaoAvisaDisfarce() throws {
        let tema = Theme.tinta
        let tamanho = CGSize(width: 420, height: 330)
        let limpo = try #require(LinkDoCorpo.destino(de: try url("https://resend.com/onboarding")))
        let torto = try #require(
            LinkDoCorpo.destino(de: try url("https://xn--80ak6aa92e.com/conta"))
        )
        #expect(limpo.aviso == nil)
        #expect(torto.aviso != nil)
        let semAviso = try #require(
            Render.snapshot(
                cartao(limpo, tema: tema), named: "confirmacao-link-limpo-tinta",
                size: tamanho, theme: tema, scale: 2
            )
        )
        let comAviso = try #require(
            Render.snapshot(
                cartao(torto, tema: tema), named: "confirmacao-link-idn-tinta",
                size: tamanho, theme: tema, scale: 2
            )
        )
        #expect(comAviso.pixelsDiffering(from: semAviso) > 0)
        #expect(tinta(comAviso, fundo: tema.paper) > tinta(semAviso, fundo: tema.paper),
                "o aviso de disfarce tem de acrescentar desenho, não sumir")
    }

    /// O cartão cabe na coluna da prévia (380pt), que é a superfície mais
    /// estreita onde ele aparece.
    @Test("o cartão cabe na coluna da prévia")
    func cartaoCabeNaPrevia() throws {
        let tema = Theme.okami
        let destino = try #require(
            LinkDoCorpo.destino(de: try url(
                "https://mail.notificacoes.resend.com/onboarding?token=abc123&u=9"
            ))
        )
        let rep = try #require(
            Render.snapshot(
                cartao(destino, tema: tema),
                named: "confirmacao-link-previa",
                size: CGSize(width: 380, height: 330),
                theme: tema,
                scale: 2
            )
        )
        #expect(rep.pixelsWide == 760)
        #expect(tinta(rep, fundo: tema.paper) > 1000)
    }
}
