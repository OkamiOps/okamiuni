import AppKit
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// A citação do compositor: o original **desenhado**, e não cuspido como
/// texto cru.
///
/// A reclamação de 15/10/2026, nas palavras do dono: "quando eu vou responder
/// e-mail o resto do e-mail fica totalmente sem formatação, ou seja fica
/// péssimo e não consigo entender contexto para responder". A captura dele era
/// um digest do Todoist — tabela, botão, link de rastreio — virando parágrafos
/// soltos com buracos em branco no meio.
///
/// A fixture abaixo é desse feitio de propósito: tabela de duas colunas,
/// botão em `<a>` com fundo, e três URLs de rastreio de verdade, com `utm_`,
/// hash e id de campanha.
@Suite("A citação do compositor")
@MainActor
struct ComposerQuoteRenderTests {

    private static let size = CGSize(width: 980, height: 700)

    /// O rastreio comprido que fazia a citação em texto virar um muro.
    private static let rastreio = "https://click.e.todoist.com/f/a/8kQb3Zx9-LmNpQrStUvWxYz/AA/"
        + "H1Jk2Lm3Np4Qr5St6Uv7Wx8Yz9Ab0Cd1Ef2Gh3Ij4Kl5Mn6Op7Qr8St9Uv0Wx"
        + "?utm_source=digest&utm_medium=email&utm_campaign=daily_2026_10_15&cid=99173402"

    private static var html: String {
        """
        <html><body style="margin:0;font-family:-apple-system,Helvetica,sans-serif">
        <table width="100%" cellpadding="0" cellspacing="0">
          <tr><td style="padding:18px 20px;background:#e44332;color:#fff">
            <strong style="font-size:17px">Todoist · Resumo de hoje</strong>
          </td></tr>
          <tr><td style="padding:18px 20px;color:#202020">
            <p style="margin:0 0 12px">Você tem <strong>4 tarefas</strong> para hoje.</p>
            <table width="100%" cellpadding="6" cellspacing="0" style="border-collapse:collapse">
              <tr><td style="border-bottom:1px solid #eee">Fechar a proposta da Marina</td>
                  <td style="border-bottom:1px solid #eee;text-align:right;color:#888">hoje</td></tr>
              <tr><td style="border-bottom:1px solid #eee">Revisar o contrato Aitherion</td>
                  <td style="border-bottom:1px solid #eee;text-align:right;color:#888">hoje</td></tr>
              <tr><td style="border-bottom:1px solid #eee">Liberar o Tally público</td>
                  <td style="border-bottom:1px solid #eee;text-align:right;color:#888">sáb</td></tr>
              <tr><td>Pagar os créditos</td>
                  <td style="text-align:right;color:#888">05/09</td></tr>
            </table>
            <p style="margin:18px 0 0">
              <a href="\(rastreio)"
                 style="display:inline-block;padding:11px 20px;background:#e44332;color:#fff;
                        border-radius:6px;text-decoration:none;font-weight:600">Abrir no Todoist</a>
            </p>
            <p style="margin:18px 0 0;font-size:12px;color:#999">
              Não quer mais estes e-mails?
              <a href="\(rastreio)&amp;action=unsubscribe">Cancelar a inscrição</a>.
            </p>
          </td></tr>
        </table>
        </body></html>
        """
    }

    /// O mesmo digest como o servidor o manda em `text/plain`: é isto que a
    /// citação mostrava antes, e é o caminho que sobra quando não há HTML.
    private static let texto = [
        "Todoist · Resumo de hoje",
        "Você tem 4 tarefas para hoje.",
        "Abrir no Todoist: \(rastreio)",
        "Cancelar a inscrição: \(rastreio)&action=unsubscribe",
    ]

    private static func mensagem(html: String?) -> Message {
        Message(
            id: "digest", accountID: "a1",
            from: Contact(name: "Todoist", address: "no-reply@todoist.com"),
            receivedAt: Date(timeIntervalSince1970: 1_800_000_000),
            subject: "Resumo de hoje · 4 tarefas",
            snippet: "Você tem 4 tarefas para hoje.",
            body: texto, tags: [], bucket: .today, isRead: false,
            summary: nil, detectedEvent: nil, bodyHTML: html
        )
    }

    private func loja(html: String?) async -> MailStore {
        let store = MailStore(source: InMemoryMailSource(
            accounts: Fixtures.accounts,
            messages: [Self.mensagem(html: html)] + Fixtures.messages,
            agenda: []
        ))
        await store.load()
        return store
    }

    private func janela(_ store: MailStore) -> some View {
        ComposerWindow(
            store: store, mode: .reply(messageID: "digest"), debugHistoryOpen: true
        )
    }

    @Test("a citação aberta desenha o original formatado", arguments: [
        "vidro-noite", "okami",
    ])
    func quotedHTMLRenders(id: String) async throws {
        let theme = try #require(Theme.named(id))
        let store = await loja(html: Self.html)
        let rep = try #require(Render.snapshot(
            janela(store),
            named: "compositor-citacao-html-\(id)",
            size: Self.size, theme: theme
        ))
        #expect(rep.pixelsWide == Int(Self.size.width))
        #expect(rep.pixelsHigh == Int(Self.size.height))
    }

    /// Sem HTML, o texto continua sendo o caminho — mas o link de rastreio
    /// vira o domínio, e não um muro de duzentos caracteres.
    @Test("sem HTML, a citação mostra o texto com o link encurtado")
    func quotedPlainTextRenders() async throws {
        let theme = try #require(Theme.named("okami"))
        let store = await loja(html: nil)
        let rep = try #require(Render.snapshot(
            janela(store),
            named: "compositor-citacao-texto-okami",
            size: Self.size, theme: theme
        ))
        #expect(rep.pixelsWide == Int(Self.size.width))
    }
}
